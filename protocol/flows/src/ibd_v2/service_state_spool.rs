//! Crash-safe staging for resumable Service State downloads.
//!
//! The resume cursor may advance only after the corresponding rows are durable.
//! This append-only spool is therefore the source of truth for Service State
//! transfer progress; a higher-level checkpoint is allowed to lag it, but must
//! never lead it.

use super::state::{ServiceStateResumeMetadata, service_state_row_fingerprint};
use blake2b_simd::Params;
use keryx_hashes::Hash;
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
};
use thiserror::Error;

const MAGIC: [u8; 8] = *b"KXSSV2\0\0";
const FORMAT_VERSION: u16 = 1;
const HEADER_PREFIX_LEN: usize = MAGIC.len() + size_of::<u16>() + 32 + 32;
const HEADER_LEN: usize = HEADER_PREFIX_LEN + 32;
const RECORD_HEADER_LEN: usize = size_of::<u64>() + size_of::<u32>() + size_of::<u32>() + 32 + 32;
const MAX_CHUNK_ROWS: u32 = 100_000;
const MAX_CHUNK_PAYLOAD_BYTES: usize = 32 * 1024 * 1024;
const HEADER_CHECKSUM_KEY: &[u8] = b"Keryx-IBD-v2-service-spool-header-v1";
const RECORD_CHECKSUM_KEY: &[u8] = b"Keryx-IBD-v2-service-spool-record-v1";

#[derive(Debug, Error)]
pub enum ServiceStateSpoolError {
    #[error("service-state spool I/O error: {0}")]
    Io(#[from] io::Error),
    #[error("service-state spool header is truncated")]
    TruncatedHeader,
    #[error("service-state spool magic is invalid")]
    InvalidMagic,
    #[error("unsupported service-state spool version {0}")]
    UnsupportedVersion(u16),
    #[error("service-state spool header checksum mismatch")]
    HeaderChecksumMismatch,
    #[error("service-state spool belongs to another network: expected genesis {expected}, found {found}")]
    WrongGenesis { expected: Hash, found: Hash },
    #[error("service-state spool belongs to another pruning point: expected {expected}, found {found}")]
    WrongPruningPoint { expected: Hash, found: Hash },
    #[error("service-state spool record checksum mismatch at file offset {offset}")]
    RecordChecksumMismatch { offset: u64 },
    #[error("service-state spool record has invalid row count {0}")]
    InvalidRowCount(u32),
    #[error("service-state spool chunk payload is too large: {0} bytes")]
    ChunkTooLarge(usize),
    #[error("service-state spool row payload is malformed")]
    InvalidPayloadShape,
    #[error("service-state spool row payload decode failed: {0}")]
    PayloadDecode(String),
    #[error("service-state spool cursor mismatch: expected {expected}, received {received}")]
    StartCursorMismatch { expected: u64, received: u64 },
    #[error("service-state spool next cursor mismatch: expected {expected}, received {received}")]
    NextCursorMismatch { expected: u64, received: u64 },
    #[error("service-state spool cursor overflow")]
    CursorOverflow,
    #[error("service-state spool last-row fingerprint mismatch at cursor {cursor}")]
    FingerprintMismatch { cursor: u64 },
    #[error("service-state spool resume metadata rejected durable record: {0}")]
    ResumeMetadata(String),
    #[error("service-state spool in-memory metadata no longer matches its durable records")]
    MetadataMismatch,
}

pub struct ServiceStateSpool {
    path: PathBuf,
    file: File,
    genesis_hash: Hash,
    pruning_point: Hash,
    metadata: ServiceStateResumeMetadata,
    truncated_tail_on_open: bool,
}

impl ServiceStateSpool {
    /// Opens or creates a spool and reconstructs its durable cursor by scanning
    /// every complete record. A torn final record is truncated back to the last
    /// fully verified boundary. Corruption of a complete record is never hidden.
    pub fn open(path: impl AsRef<Path>, genesis_hash: Hash, pruning_point: Hash) -> Result<Self, ServiceStateSpoolError> {
        let path = path.as_ref().to_path_buf();
        let parent = path.parent().filter(|parent| !parent.as_os_str().is_empty()).unwrap_or_else(|| Path::new("."));
        fs::create_dir_all(parent)?;

        let mut file = OpenOptions::new().read(true).write(true).create(true).open(&path)?;
        if file.metadata()?.len() == 0 {
            write_header(&mut file, genesis_hash, pruning_point)?;
            sync_parent_directory(parent)?;
        } else {
            validate_header(&mut file, genesis_hash, pruning_point)?;
        }

        let (metadata, _, truncated_tail_on_open) = scan_records(&mut file, pruning_point, true, false)?;
        file.seek(SeekFrom::End(0))?;

        Ok(Self { path, file, genesis_hash, pruning_point, metadata, truncated_tail_on_open })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub const fn genesis_hash(&self) -> Hash {
        self.genesis_hash
    }

    pub const fn pruning_point(&self) -> Hash {
        self.pruning_point
    }

    pub const fn metadata(&self) -> ServiceStateResumeMetadata {
        self.metadata
    }

    pub const fn truncated_tail_on_open(&self) -> bool {
        self.truncated_tail_on_open
    }

    /// Appends one already wire-validated chunk. Data and record metadata are
    /// flushed and fsynced before the in-memory resume cursor is advanced.
    pub fn append_chunk(
        &mut self,
        start_cursor: u64,
        next_cursor: u64,
        rows: &[Vec<u8>],
    ) -> Result<ServiceStateResumeMetadata, ServiceStateSpoolError> {
        let expected_start = self.metadata.next_cursor;
        if start_cursor != expected_start {
            return Err(ServiceStateSpoolError::StartCursorMismatch { expected: expected_start, received: start_cursor });
        }

        let row_count = u32::try_from(rows.len()).map_err(|_| ServiceStateSpoolError::InvalidRowCount(u32::MAX))?;
        if row_count == 0 || row_count > MAX_CHUNK_ROWS {
            return Err(ServiceStateSpoolError::InvalidRowCount(row_count));
        }
        let expected_next = start_cursor.checked_add(u64::from(row_count)).ok_or(ServiceStateSpoolError::CursorOverflow)?;
        if next_cursor != expected_next {
            return Err(ServiceStateSpoolError::NextCursorMismatch { expected: expected_next, received: next_cursor });
        }

        let last_fingerprint = service_state_row_fingerprint(rows.last().expect("non-empty row count was checked"));
        let payload = borsh::to_vec(rows).map_err(|error| ServiceStateSpoolError::PayloadDecode(error.to_string()))?;
        if payload.len() > MAX_CHUNK_PAYLOAD_BYTES {
            return Err(ServiceStateSpoolError::ChunkTooLarge(payload.len()));
        }
        validate_payload_shape(&payload, row_count)?;
        let payload_len = u32::try_from(payload.len()).map_err(|_| ServiceStateSpoolError::ChunkTooLarge(payload.len()))?;
        let checksum = record_checksum(start_cursor, row_count, payload_len, last_fingerprint, &payload);
        let header = encode_record_header(start_cursor, row_count, payload_len, last_fingerprint, checksum);

        let mut next_metadata = self.metadata;
        next_metadata
            .record_chunk(next_cursor, u64::from(row_count), last_fingerprint)
            .map_err(|error| ServiceStateSpoolError::ResumeMetadata(format!("{error:?}")))?;

        let record_offset = self.file.seek(SeekFrom::End(0))?;
        let write_result = (|| -> io::Result<()> {
            self.file.write_all(&header)?;
            self.file.write_all(&payload)?;
            self.file.flush()?;
            self.file.sync_all()
        })();
        if let Err(error) = write_result {
            let _ = self.file.set_len(record_offset);
            let _ = self.file.sync_all();
            let _ = self.file.seek(SeekFrom::End(0));
            return Err(error.into());
        }

        self.metadata = next_metadata;
        Ok(self.metadata)
    }

    /// Re-reads and verifies every durable record, returning the canonical row
    /// stream that may be MuHash-verified and imported after transfer completion.
    pub fn read_all_rows(&mut self) -> Result<Vec<Vec<u8>>, ServiceStateSpoolError> {
        let (metadata, rows, truncated) = scan_records(&mut self.file, self.pruning_point, false, true)?;
        if truncated || metadata != self.metadata {
            return Err(ServiceStateSpoolError::MetadataMismatch);
        }
        self.file.seek(SeekFrom::End(0))?;
        Ok(rows.expect("rows are collected when requested"))
    }
}

fn write_header(file: &mut File, genesis_hash: Hash, pruning_point: Hash) -> Result<(), ServiceStateSpoolError> {
    let checksum = header_checksum(FORMAT_VERSION, genesis_hash, pruning_point);
    file.seek(SeekFrom::Start(0))?;
    file.write_all(&MAGIC)?;
    file.write_all(&FORMAT_VERSION.to_le_bytes())?;
    file.write_all(&genesis_hash.as_bytes())?;
    file.write_all(&pruning_point.as_bytes())?;
    file.write_all(&checksum)?;
    file.flush()?;
    file.sync_all()?;
    Ok(())
}

fn validate_header(file: &mut File, expected_genesis: Hash, expected_pruning_point: Hash) -> Result<(), ServiceStateSpoolError> {
    if file.metadata()?.len() < HEADER_LEN as u64 {
        return Err(ServiceStateSpoolError::TruncatedHeader);
    }
    let mut header = [0u8; HEADER_LEN];
    file.seek(SeekFrom::Start(0))?;
    file.read_exact(&mut header)?;
    if header[..MAGIC.len()] != MAGIC {
        return Err(ServiceStateSpoolError::InvalidMagic);
    }

    let version_offset = MAGIC.len();
    let version = u16::from_le_bytes(header[version_offset..version_offset + size_of::<u16>()].try_into().unwrap());
    if version != FORMAT_VERSION {
        return Err(ServiceStateSpoolError::UnsupportedVersion(version));
    }
    let genesis_offset = version_offset + size_of::<u16>();
    let found_genesis = Hash::from_slice(&header[genesis_offset..genesis_offset + 32]);
    let pruning_offset = genesis_offset + 32;
    let found_pruning_point = Hash::from_slice(&header[pruning_offset..pruning_offset + 32]);
    let checksum_offset = pruning_offset + 32;
    let stored_checksum: [u8; 32] = header[checksum_offset..checksum_offset + 32].try_into().unwrap();
    let expected_checksum = header_checksum(version, found_genesis, found_pruning_point);
    if stored_checksum != expected_checksum {
        return Err(ServiceStateSpoolError::HeaderChecksumMismatch);
    }
    if found_genesis != expected_genesis {
        return Err(ServiceStateSpoolError::WrongGenesis { expected: expected_genesis, found: found_genesis });
    }
    if found_pruning_point != expected_pruning_point {
        return Err(ServiceStateSpoolError::WrongPruningPoint { expected: expected_pruning_point, found: found_pruning_point });
    }
    Ok(())
}

fn scan_records(
    file: &mut File,
    pruning_point: Hash,
    repair_truncated_tail: bool,
    collect_rows: bool,
) -> Result<(ServiceStateResumeMetadata, Option<Vec<Vec<u8>>>, bool), ServiceStateSpoolError> {
    let file_len = file.metadata()?.len();
    let mut offset = HEADER_LEN as u64;
    let mut metadata = ServiceStateResumeMetadata::new(pruning_point);
    let mut collected = collect_rows.then(Vec::new);
    let mut truncated = false;

    while offset < file_len {
        let remaining = file_len - offset;
        if remaining < RECORD_HEADER_LEN as u64 {
            truncate_tail(file, offset, repair_truncated_tail)?;
            truncated = true;
            break;
        }

        let mut record_header = [0u8; RECORD_HEADER_LEN];
        file.seek(SeekFrom::Start(offset))?;
        file.read_exact(&mut record_header)?;
        let start_cursor = u64::from_le_bytes(record_header[0..8].try_into().unwrap());
        let row_count = u32::from_le_bytes(record_header[8..12].try_into().unwrap());
        let payload_len = u32::from_le_bytes(record_header[12..16].try_into().unwrap()) as usize;
        let last_fingerprint: [u8; 32] = record_header[16..48].try_into().unwrap();
        let stored_checksum: [u8; 32] = record_header[48..80].try_into().unwrap();

        if row_count == 0 || row_count > MAX_CHUNK_ROWS {
            return Err(ServiceStateSpoolError::InvalidRowCount(row_count));
        }
        if payload_len > MAX_CHUNK_PAYLOAD_BYTES {
            return Err(ServiceStateSpoolError::ChunkTooLarge(payload_len));
        }

        let record_len =
            (RECORD_HEADER_LEN as u64).checked_add(payload_len as u64).ok_or(ServiceStateSpoolError::ChunkTooLarge(payload_len))?;
        if remaining < record_len {
            truncate_tail(file, offset, repair_truncated_tail)?;
            truncated = true;
            break;
        }

        let mut payload = vec![0u8; payload_len];
        file.read_exact(&mut payload)?;
        let expected_checksum = record_checksum(start_cursor, row_count, payload_len as u32, last_fingerprint, &payload);
        if stored_checksum != expected_checksum {
            return Err(ServiceStateSpoolError::RecordChecksumMismatch { offset });
        }
        validate_payload_shape(&payload, row_count)?;
        let rows: Vec<Vec<u8>> =
            borsh::from_slice(&payload).map_err(|error| ServiceStateSpoolError::PayloadDecode(error.to_string()))?;
        if rows.len() != row_count as usize {
            return Err(ServiceStateSpoolError::InvalidPayloadShape);
        }

        let expected_start = metadata.next_cursor;
        if start_cursor != expected_start {
            return Err(ServiceStateSpoolError::StartCursorMismatch { expected: expected_start, received: start_cursor });
        }
        let next_cursor = start_cursor.checked_add(u64::from(row_count)).ok_or(ServiceStateSpoolError::CursorOverflow)?;
        let computed_fingerprint = service_state_row_fingerprint(rows.last().expect("record row count was checked"));
        if computed_fingerprint != last_fingerprint {
            return Err(ServiceStateSpoolError::FingerprintMismatch { cursor: next_cursor });
        }
        metadata
            .record_chunk(next_cursor, u64::from(row_count), last_fingerprint)
            .map_err(|error| ServiceStateSpoolError::ResumeMetadata(format!("{error:?}")))?;
        if let Some(collected) = &mut collected {
            collected.extend(rows);
        }
        offset = offset.checked_add(record_len).ok_or(ServiceStateSpoolError::CursorOverflow)?;
    }

    Ok((metadata, collected, truncated))
}

fn truncate_tail(file: &mut File, offset: u64, allowed: bool) -> Result<(), ServiceStateSpoolError> {
    if !allowed {
        return Err(ServiceStateSpoolError::Io(io::Error::new(io::ErrorKind::UnexpectedEof, "truncated service-state spool record")));
    }
    file.set_len(offset)?;
    file.sync_all()?;
    Ok(())
}

fn validate_payload_shape(payload: &[u8], expected_rows: u32) -> Result<(), ServiceStateSpoolError> {
    if payload.len() < size_of::<u32>() {
        return Err(ServiceStateSpoolError::InvalidPayloadShape);
    }
    let encoded_rows = u32::from_le_bytes(payload[..4].try_into().unwrap());
    if encoded_rows != expected_rows || encoded_rows == 0 || encoded_rows > MAX_CHUNK_ROWS {
        return Err(ServiceStateSpoolError::InvalidPayloadShape);
    }

    let mut cursor = 4usize;
    for _ in 0..encoded_rows {
        let length_end = cursor.checked_add(4).ok_or(ServiceStateSpoolError::InvalidPayloadShape)?;
        if length_end > payload.len() {
            return Err(ServiceStateSpoolError::InvalidPayloadShape);
        }
        let row_len = u32::from_le_bytes(payload[cursor..length_end].try_into().unwrap()) as usize;
        cursor = length_end.checked_add(row_len).ok_or(ServiceStateSpoolError::InvalidPayloadShape)?;
        if cursor > payload.len() {
            return Err(ServiceStateSpoolError::InvalidPayloadShape);
        }
    }
    if cursor != payload.len() {
        return Err(ServiceStateSpoolError::InvalidPayloadShape);
    }
    Ok(())
}

fn header_checksum(version: u16, genesis_hash: Hash, pruning_point: Hash) -> [u8; 32] {
    let mut state = Params::new().hash_length(32).key(HEADER_CHECKSUM_KEY).to_state();
    state.update(&MAGIC);
    state.update(&version.to_le_bytes());
    state.update(&genesis_hash.as_bytes());
    state.update(&pruning_point.as_bytes());
    digest32(state.finalize().as_bytes())
}

fn record_checksum(start_cursor: u64, row_count: u32, payload_len: u32, fingerprint: [u8; 32], payload: &[u8]) -> [u8; 32] {
    let mut state = Params::new().hash_length(32).key(RECORD_CHECKSUM_KEY).to_state();
    state.update(&start_cursor.to_le_bytes());
    state.update(&row_count.to_le_bytes());
    state.update(&payload_len.to_le_bytes());
    state.update(&fingerprint);
    state.update(payload);
    digest32(state.finalize().as_bytes())
}

fn digest32(bytes: &[u8]) -> [u8; 32] {
    let mut digest = [0u8; 32];
    digest.copy_from_slice(bytes);
    digest
}

fn encode_record_header(
    start_cursor: u64,
    row_count: u32,
    payload_len: u32,
    fingerprint: [u8; 32],
    checksum: [u8; 32],
) -> [u8; RECORD_HEADER_LEN] {
    let mut header = [0u8; RECORD_HEADER_LEN];
    header[0..8].copy_from_slice(&start_cursor.to_le_bytes());
    header[8..12].copy_from_slice(&row_count.to_le_bytes());
    header[12..16].copy_from_slice(&payload_len.to_le_bytes());
    header[16..48].copy_from_slice(&fingerprint);
    header[48..80].copy_from_slice(&checksum);
    header
}

#[cfg(unix)]
fn sync_parent_directory(parent: &Path) -> io::Result<()> {
    fs::File::open(parent)?.sync_all()
}

#[cfg(not(unix))]
fn sync_parent_directory(_parent: &Path) -> io::Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{RECORD_HEADER_LEN, ServiceStateSpool, ServiceStateSpoolError, encode_record_header};
    use keryx_hashes::Hash;
    use std::{
        fs::{self, OpenOptions},
        io::Write,
        path::PathBuf,
    };
    use uuid::Uuid;

    fn hash(byte: u8) -> Hash {
        Hash::from_bytes([byte; 32])
    }

    fn test_path() -> PathBuf {
        let directory = std::env::temp_dir().join(format!("keryx-ibd-v2-service-spool-{}", Uuid::new_v4()));
        fs::create_dir_all(&directory).unwrap();
        directory.join("service-state.spool")
    }

    #[test]
    fn durable_chunks_survive_reopen_and_reconstruct_rows() {
        let path = test_path();
        let mut spool = ServiceStateSpool::open(&path, hash(1), hash(2)).unwrap();
        assert_eq!(spool.metadata().next_cursor, 0);
        spool.append_chunk(0, 2, &[b"row-a".to_vec(), b"row-b".to_vec()]).unwrap();
        spool.append_chunk(2, 3, &[b"row-c".to_vec()]).unwrap();
        assert_eq!(spool.metadata().next_cursor, 3);
        drop(spool);

        let mut reopened = ServiceStateSpool::open(&path, hash(1), hash(2)).unwrap();
        assert!(!reopened.truncated_tail_on_open());
        assert_eq!(reopened.metadata().next_cursor, 3);
        assert_eq!(reopened.metadata().chunk_count, 2);
        assert_eq!(reopened.read_all_rows().unwrap(), vec![b"row-a".to_vec(), b"row-b".to_vec(), b"row-c".to_vec()]);
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn torn_record_header_is_truncated_to_last_durable_boundary() {
        let path = test_path();
        let mut spool = ServiceStateSpool::open(&path, hash(1), hash(2)).unwrap();
        spool.append_chunk(0, 1, &[b"row-a".to_vec()]).unwrap();
        drop(spool);
        let durable_len = fs::metadata(&path).unwrap().len();
        let mut file = OpenOptions::new().append(true).open(&path).unwrap();
        file.write_all(&[0xaa; 7]).unwrap();
        file.sync_all().unwrap();
        drop(file);

        let reopened = ServiceStateSpool::open(&path, hash(1), hash(2)).unwrap();
        assert!(reopened.truncated_tail_on_open());
        assert_eq!(reopened.metadata().next_cursor, 1);
        assert_eq!(fs::metadata(&path).unwrap().len(), durable_len);
        drop(reopened);
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn torn_record_payload_is_truncated_to_last_durable_boundary() {
        let path = test_path();
        let mut spool = ServiceStateSpool::open(&path, hash(1), hash(2)).unwrap();
        spool.append_chunk(0, 1, &[b"row-a".to_vec()]).unwrap();
        drop(spool);
        let durable_len = fs::metadata(&path).unwrap().len();
        let header = encode_record_header(1, 1, 100, [4; 32], [5; 32]);
        assert_eq!(header.len(), RECORD_HEADER_LEN);
        let mut file = OpenOptions::new().append(true).open(&path).unwrap();
        file.write_all(&header).unwrap();
        file.write_all(&[1, 2, 3, 4, 5]).unwrap();
        file.sync_all().unwrap();
        drop(file);

        let reopened = ServiceStateSpool::open(&path, hash(1), hash(2)).unwrap();
        assert!(reopened.truncated_tail_on_open());
        assert_eq!(reopened.metadata().next_cursor, 1);
        assert_eq!(fs::metadata(&path).unwrap().len(), durable_len);
        drop(reopened);
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn complete_corrupted_record_is_rejected_not_truncated() {
        let path = test_path();
        let mut spool = ServiceStateSpool::open(&path, hash(1), hash(2)).unwrap();
        spool.append_chunk(0, 1, &[b"row-a".to_vec()]).unwrap();
        drop(spool);
        let mut bytes = fs::read(&path).unwrap();
        *bytes.last_mut().unwrap() ^= 0x55;
        fs::write(&path, bytes).unwrap();

        assert!(matches!(
            ServiceStateSpool::open(&path, hash(1), hash(2)),
            Err(ServiceStateSpoolError::RecordChecksumMismatch { .. })
        ));
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn wrong_network_or_pruning_point_is_rejected() {
        let path = test_path();
        drop(ServiceStateSpool::open(&path, hash(1), hash(2)).unwrap());
        assert!(matches!(ServiceStateSpool::open(&path, hash(9), hash(2)), Err(ServiceStateSpoolError::WrongGenesis { .. })));
        assert!(matches!(ServiceStateSpool::open(&path, hash(1), hash(9)), Err(ServiceStateSpoolError::WrongPruningPoint { .. })));
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn append_rejects_cursor_that_would_skip_durable_rows() {
        let path = test_path();
        let mut spool = ServiceStateSpool::open(&path, hash(1), hash(2)).unwrap();
        assert!(matches!(
            spool.append_chunk(1, 2, &[b"row-a".to_vec()]),
            Err(ServiceStateSpoolError::StartCursorMismatch { expected: 0, received: 1 })
        ));
        assert_eq!(spool.metadata().next_cursor, 0);
        drop(spool);
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }
}
