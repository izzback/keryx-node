//! Durable IBD v2 checkpoints.
//!
//! Service-state rows are appended to a journal before the resume cursor is
//! committed. Metadata alternates between two fixed-size slots, so a crash
//! while writing the newest slot leaves the previous checkpoint readable on
//! both Unix and Windows.

use super::state::{ServiceStateResumeMetadata, service_state_row_fingerprint};
use keryx_hashes::Hash;
use std::{
    cmp::Reverse,
    fs::{self, File, OpenOptions},
    io::{self, Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
};

const MAGIC: &[u8; 8] = b"KIBDSS01";
const VERSION: u32 = 1;
const META_LEN: usize = 8 + 4 + 8 + 32 + 8 + 8 + 8 + 1 + 32 + 8;
const ROWS_FILE: &str = "rows.bin";
const META_A_FILE: &str = "checkpoint-a.bin";
const META_B_FILE: &str = "checkpoint-b.bin";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct CheckpointRecord {
    generation: u64,
    metadata: ServiceStateResumeMetadata,
    data_len: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoadedServiceState {
    pub metadata: ServiceStateResumeMetadata,
    pub rows: Vec<Vec<u8>>,
}

#[derive(Debug)]
pub struct ServiceStateCheckpointStore {
    dir: PathBuf,
    rows_path: PathBuf,
    pruning_point: Hash,
    generation: u64,
    data_len: u64,
    row_count: u64,
}

impl ServiceStateCheckpointStore {
    pub fn open(root: impl AsRef<Path>, pruning_point: Hash) -> io::Result<(Self, Option<LoadedServiceState>)> {
        let dir = root.as_ref().join("service-state");
        fs::create_dir_all(&dir)?;
        let rows_path = dir.join(ROWS_FILE);
        let mut candidates = [dir.join(META_A_FILE), dir.join(META_B_FILE)]
            .into_iter()
            .filter_map(|path| read_record(&path).ok().flatten())
            .filter(|record| record.metadata.pruning_point == pruning_point)
            .collect::<Vec<_>>();
        candidates.sort_by_key(|record| Reverse(record.generation));

        for record in candidates {
            if let Ok(rows) = read_rows(&rows_path, record) {
                truncate_rows_to(&rows_path, record.data_len)?;
                let store = Self {
                    dir,
                    rows_path,
                    pruning_point,
                    generation: record.generation,
                    data_len: record.data_len,
                    row_count: record.metadata.row_count,
                };
                return Ok((store, Some(LoadedServiceState { metadata: record.metadata, rows })));
            }
        }

        // No usable checkpoint exists. Any row journal without valid metadata
        // is uncommitted staging data and must not influence a fresh transfer.
        remove_if_exists(&rows_path)?;
        remove_if_exists(&dir.join(META_A_FILE))?;
        remove_if_exists(&dir.join(META_B_FILE))?;
        let store = Self { dir, rows_path, pruning_point, generation: 0, data_len: 0, row_count: 0 };
        Ok((store, None))
    }

    /// Append accepted rows and then commit the supplied cursor metadata.
    ///
    /// Ordering is deliberate: journal -> fsync -> alternate metadata slot ->
    /// fsync. A crash after the journal fsync but before metadata commit leaves
    /// extra bytes which are discarded when reopening the previous checkpoint.
    pub fn append_chunk(&mut self, rows: &[Vec<u8>], metadata: ServiceStateResumeMetadata) -> io::Result<()> {
        if rows.is_empty() {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "cannot checkpoint an empty service-state chunk"));
        }
        if metadata.pruning_point != self.pruning_point {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "checkpoint pruning point mismatch"));
        }
        let expected_rows = self
            .row_count
            .checked_add(rows.len() as u64)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "service-state row count overflow"))?;
        if metadata.row_count != expected_rows || metadata.next_cursor != metadata.row_count {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "checkpoint cursor does not match durable row count"));
        }
        let expected_fingerprint = service_state_row_fingerprint(rows.last().expect("non-empty checked above"));
        if metadata.last_row_fingerprint != Some(expected_fingerprint) {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "checkpoint last-row fingerprint mismatch"));
        }

        let mut file = OpenOptions::new().create(true).append(true).read(true).open(&self.rows_path)?;
        for row in rows {
            let len = u32::try_from(row.len())
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "service-state row exceeds u32 framing"))?;
            file.write_all(&len.to_le_bytes())?;
            file.write_all(row)?;
        }
        file.sync_all()?;
        let data_len = file.metadata()?.len();

        let generation = self.generation.saturating_add(1);
        let record = CheckpointRecord { generation, metadata, data_len };
        let slot = if generation & 1 == 0 { self.dir.join(META_A_FILE) } else { self.dir.join(META_B_FILE) };
        write_record(&slot, record)?;

        self.generation = generation;
        self.data_len = data_len;
        self.row_count = metadata.row_count;
        Ok(())
    }

    /// Delete all staging data after a successful final consensus import, or
    /// when the caller intentionally abandons the checkpoint.
    pub fn reset(&mut self) -> io::Result<()> {
        remove_if_exists(&self.rows_path)?;
        remove_if_exists(&self.dir.join(META_A_FILE))?;
        remove_if_exists(&self.dir.join(META_B_FILE))?;
        self.generation = 0;
        self.data_len = 0;
        self.row_count = 0;
        Ok(())
    }

    pub const fn durable_row_count(&self) -> u64 {
        self.row_count
    }

    pub const fn durable_data_len(&self) -> u64 {
        self.data_len
    }
}

fn write_record(path: &Path, record: CheckpointRecord) -> io::Result<()> {
    let bytes = encode_record(record);
    debug_assert_eq!(bytes.len(), META_LEN);
    let mut file = OpenOptions::new().create(true).write(true).truncate(true).open(path)?;
    file.write_all(&bytes)?;
    file.sync_all()
}

fn read_record(path: &Path) -> io::Result<Option<CheckpointRecord>> {
    let mut file = match File::open(path) {
        Ok(file) => file,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(err),
    };
    if file.metadata()?.len() != META_LEN as u64 {
        return Ok(None);
    }
    let mut bytes = vec![0u8; META_LEN];
    file.read_exact(&mut bytes)?;
    decode_record(&bytes).map(Some)
}

fn encode_record(record: CheckpointRecord) -> Vec<u8> {
    let mut out = Vec::with_capacity(META_LEN);
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&VERSION.to_le_bytes());
    out.extend_from_slice(&record.generation.to_le_bytes());
    out.extend_from_slice(&record.metadata.pruning_point.as_bytes());
    out.extend_from_slice(&record.metadata.next_cursor.to_le_bytes());
    out.extend_from_slice(&record.metadata.chunk_count.to_le_bytes());
    out.extend_from_slice(&record.metadata.row_count.to_le_bytes());
    match record.metadata.last_row_fingerprint {
        Some(fingerprint) => {
            out.push(1);
            out.extend_from_slice(&fingerprint);
        }
        None => {
            out.push(0);
            out.extend_from_slice(&[0; 32]);
        }
    }
    out.extend_from_slice(&record.data_len.to_le_bytes());
    out
}

fn decode_record(bytes: &[u8]) -> io::Result<CheckpointRecord> {
    if bytes.len() != META_LEN || &bytes[..8] != MAGIC {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid IBD v2 checkpoint header"));
    }
    let mut pos = 8;
    let version = take_u32(bytes, &mut pos)?;
    if version != VERSION {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "unsupported IBD v2 checkpoint version"));
    }
    let generation = take_u64(bytes, &mut pos)?;
    let mut pp = [0u8; 32];
    pp.copy_from_slice(take(bytes, &mut pos, 32)?);
    let next_cursor = take_u64(bytes, &mut pos)?;
    let chunk_count = take_u64(bytes, &mut pos)?;
    let row_count = take_u64(bytes, &mut pos)?;
    let has_fingerprint = *take(bytes, &mut pos, 1)?.first().unwrap();
    let mut fingerprint = [0u8; 32];
    fingerprint.copy_from_slice(take(bytes, &mut pos, 32)?);
    let data_len = take_u64(bytes, &mut pos)?;
    if pos != META_LEN || has_fingerprint > 1 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid IBD v2 checkpoint metadata"));
    }
    let last_row_fingerprint = (has_fingerprint == 1).then_some(fingerprint);
    let metadata =
        ServiceStateResumeMetadata { pruning_point: Hash::from_bytes(pp), next_cursor, chunk_count, row_count, last_row_fingerprint };
    Ok(CheckpointRecord { generation, metadata, data_len })
}

fn read_rows(path: &Path, record: CheckpointRecord) -> io::Result<Vec<Vec<u8>>> {
    if record.metadata.next_cursor != record.metadata.row_count {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "checkpoint cursor/row-count mismatch"));
    }
    let mut file = File::open(path)?;
    if file.metadata()?.len() < record.data_len {
        return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "service-state journal shorter than checkpoint"));
    }
    let mut rows = Vec::with_capacity(usize::try_from(record.metadata.row_count).unwrap_or(0));
    let mut consumed = 0u64;
    while consumed < record.data_len {
        let mut len_bytes = [0u8; 4];
        file.read_exact(&mut len_bytes)?;
        consumed = consumed.saturating_add(4);
        let len = u32::from_le_bytes(len_bytes) as usize;
        let framed_end = consumed
            .checked_add(len as u64)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "service-state journal length overflow"))?;
        if framed_end > record.data_len {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "service-state journal frame crosses checkpoint boundary"));
        }
        let mut row = vec![0u8; len];
        file.read_exact(&mut row)?;
        consumed = framed_end;
        rows.push(row);
    }
    if rows.len() as u64 != record.metadata.row_count {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "service-state journal row count mismatch"));
    }
    match (rows.last(), record.metadata.last_row_fingerprint) {
        (Some(row), Some(expected)) if service_state_row_fingerprint(row) == expected => {}
        (None, None) if record.metadata.row_count == 0 => {}
        _ => return Err(io::Error::new(io::ErrorKind::InvalidData, "service-state journal fingerprint mismatch")),
    }
    Ok(rows)
}

fn truncate_rows_to(path: &Path, len: u64) -> io::Result<()> {
    let mut file = OpenOptions::new().create(true).write(true).open(path)?;
    if file.metadata()?.len() != len {
        file.set_len(len)?;
        file.seek(SeekFrom::Start(len))?;
        file.sync_all()?;
    }
    Ok(())
}

fn remove_if_exists(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(err) => Err(err),
    }
}

fn take<'a>(bytes: &'a [u8], pos: &mut usize, len: usize) -> io::Result<&'a [u8]> {
    let end = pos.checked_add(len).ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "checkpoint field overflow"))?;
    let out = bytes.get(*pos..end).ok_or_else(|| io::Error::new(io::ErrorKind::UnexpectedEof, "truncated checkpoint metadata"))?;
    *pos = end;
    Ok(out)
}

fn take_u32(bytes: &[u8], pos: &mut usize) -> io::Result<u32> {
    Ok(u32::from_le_bytes(take(bytes, pos, 4)?.try_into().unwrap()))
}

fn take_u64(bytes: &[u8], pos: &mut usize) -> io::Result<u64> {
    Ok(u64::from_le_bytes(take(bytes, pos, 8)?.try_into().unwrap()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_root(label: &str) -> PathBuf {
        let nonce = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        std::env::temp_dir().join(format!("keryx-ibd-v2-{label}-{}-{nonce}", std::process::id()))
    }

    fn pp(byte: u8) -> Hash {
        Hash::from_bytes([byte; 32])
    }

    fn advance(metadata: &mut ServiceStateResumeMetadata, rows: &[Vec<u8>]) {
        let next = metadata.next_cursor + rows.len() as u64;
        metadata.record_chunk(next, rows.len() as u64, service_state_row_fingerprint(rows.last().unwrap())).unwrap();
    }

    #[test]
    fn checkpoint_survives_reopen() {
        let root = temp_root("reopen");
        let pruning_point = pp(1);
        let (mut store, loaded) = ServiceStateCheckpointStore::open(&root, pruning_point).unwrap();
        assert!(loaded.is_none());
        let rows = vec![b"row-a".to_vec(), b"row-b".to_vec()];
        let mut metadata = ServiceStateResumeMetadata::new(pruning_point);
        advance(&mut metadata, &rows);
        store.append_chunk(&rows, metadata).unwrap();
        drop(store);

        let (store, loaded) = ServiceStateCheckpointStore::open(&root, pruning_point).unwrap();
        let loaded = loaded.unwrap();
        assert_eq!(loaded.metadata, metadata);
        assert_eq!(loaded.rows, rows);
        assert_eq!(store.durable_row_count(), 2);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn reopen_discards_uncommitted_tail() {
        let root = temp_root("tail");
        let pruning_point = pp(2);
        let (mut store, _) = ServiceStateCheckpointStore::open(&root, pruning_point).unwrap();
        let rows = vec![b"committed".to_vec()];
        let mut metadata = ServiceStateResumeMetadata::new(pruning_point);
        advance(&mut metadata, &rows);
        store.append_chunk(&rows, metadata).unwrap();
        let committed_len = store.durable_data_len();
        drop(store);

        let rows_path = root.join("service-state").join(ROWS_FILE);
        let mut file = OpenOptions::new().append(true).open(&rows_path).unwrap();
        file.write_all(&1234u32.to_le_bytes()).unwrap();
        file.write_all(b"crash-tail").unwrap();
        file.sync_all().unwrap();
        assert!(file.metadata().unwrap().len() > committed_len);
        drop(file);

        let (store, loaded) = ServiceStateCheckpointStore::open(&root, pruning_point).unwrap();
        assert_eq!(loaded.unwrap().rows, rows);
        assert_eq!(fs::metadata(rows_path).unwrap().len(), committed_len);
        assert_eq!(store.durable_data_len(), committed_len);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn different_pruning_point_resets_staging() {
        let root = temp_root("pruning-point");
        let (mut store, _) = ServiceStateCheckpointStore::open(&root, pp(3)).unwrap();
        let rows = vec![b"old".to_vec()];
        let mut metadata = ServiceStateResumeMetadata::new(pp(3));
        advance(&mut metadata, &rows);
        store.append_chunk(&rows, metadata).unwrap();
        drop(store);

        let (store, loaded) = ServiceStateCheckpointStore::open(&root, pp(4)).unwrap();
        assert!(loaded.is_none());
        assert_eq!(store.durable_row_count(), 0);
        fs::remove_dir_all(root).unwrap();
    }
}
