//! Durable retry backlog for recent PoM possession proofs.
//!
//! Phase 5 intentionally does not recover historical proofs outside the serve
//! horizon. This file only persists hashes that were already identified as
//! missing a still-servable recent proof. It is a recovery hint, never a source
//! of consensus truth.

use blake2b_simd::Params;
use borsh::{BorshDeserialize, BorshSerialize};
use keryx_hashes::Hash;
use std::{
    collections::{HashSet, VecDeque},
    fs::{self, OpenOptions},
    io::{self, Write},
    path::{Path, PathBuf},
};
use thiserror::Error;
use uuid::Uuid;

const FILE_NAME: &str = "pom-reproof.bin";
const MAGIC: [u8; 8] = *b"KXPOMQ1\0";
const FORMAT_VERSION: u16 = 1;
const HEADER_LEN: usize = MAGIC.len() + size_of::<u16>() + size_of::<u32>() + 32;
const MAX_PAYLOAD_BYTES: usize = 256 * 1024;
const CHECKSUM_KEY: &[u8] = b"Keryx-IBD-v2-pom-reproof-v1";

/// Matches the existing in-memory guard-rail bound. A malformed or hostile
/// naked band can therefore never make the durable retry state grow without
/// bound.
pub const POM_REPROOF_BACKLOG_CAP: usize = 4096;

#[derive(Debug, Clone, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
struct PomReproofSnapshotV1 {
    genesis_hash: Hash,
    hashes: Vec<Hash>,
}

impl PomReproofSnapshotV1 {
    fn validate(&self, expected_genesis: Hash) -> Result<(), PomReproofRecoveryError> {
        if self.genesis_hash != expected_genesis {
            return Err(PomReproofRecoveryError::WrongGenesis { expected: expected_genesis, found: self.genesis_hash });
        }
        if self.hashes.len() > POM_REPROOF_BACKLOG_CAP {
            return Err(PomReproofRecoveryError::TooManyCandidates(self.hashes.len()));
        }
        let unique: HashSet<Hash> = self.hashes.iter().copied().collect();
        if unique.len() != self.hashes.len() {
            return Err(PomReproofRecoveryError::DuplicateCandidate);
        }
        Ok(())
    }
}

#[derive(Debug, Error)]
pub enum PomReproofRecoveryError {
    #[error("PoM re-proof recovery I/O error: {0}")]
    Io(#[from] io::Error),
    #[error("PoM re-proof recovery header is truncated")]
    TruncatedHeader,
    #[error("PoM re-proof recovery magic is invalid")]
    InvalidMagic,
    #[error("unsupported PoM re-proof recovery version {0}")]
    UnsupportedVersion(u16),
    #[error("PoM re-proof recovery payload is too large: {0} bytes")]
    PayloadTooLarge(usize),
    #[error("PoM re-proof recovery length mismatch: declared {declared} bytes, found {actual} bytes")]
    LengthMismatch { declared: usize, actual: usize },
    #[error("PoM re-proof recovery checksum mismatch")]
    ChecksumMismatch,
    #[error("PoM re-proof recovery payload decode failed: {0}")]
    Decode(String),
    #[error("PoM re-proof recovery belongs to another network: expected genesis {expected}, found {found}")]
    WrongGenesis { expected: Hash, found: Hash },
    #[error("PoM re-proof recovery contains too many candidates: {0}")]
    TooManyCandidates(usize),
    #[error("PoM re-proof recovery contains a duplicate candidate")]
    DuplicateCandidate,
}

/// Crash-safe FIFO of hashes requiring a still-servable possession proof.
///
/// `peek` deliberately does not remove entries. A caller must acknowledge a
/// candidate only after it has either adopted the proof or established that the
/// candidate no longer needs recovery. This avoids the crash window inherent in
/// take-then-requeue retry queues.
#[derive(Debug)]
pub struct PomReproofRecovery {
    path: PathBuf,
    genesis_hash: Hash,
    queue: VecDeque<Hash>,
    dedup: HashSet<Hash>,
}

impl PomReproofRecovery {
    pub fn open(root: impl AsRef<Path>, genesis_hash: Hash) -> Result<Self, PomReproofRecoveryError> {
        let root = root.as_ref();
        fs::create_dir_all(root)?;
        let path = root.join(FILE_NAME);
        let snapshot = match load_snapshot(&path, genesis_hash) {
            Ok(snapshot) => snapshot,
            Err(PomReproofRecoveryError::Io(error)) if error.kind() == io::ErrorKind::NotFound => {
                PomReproofSnapshotV1 { genesis_hash, hashes: Vec::new() }
            }
            Err(error) => return Err(error),
        };
        let queue: VecDeque<Hash> = snapshot.hashes.into();
        let dedup = queue.iter().copied().collect();
        Ok(Self { path, genesis_hash, queue, dedup })
    }

    pub fn len(&self) -> usize {
        self.queue.len()
    }

    pub fn is_empty(&self) -> bool {
        self.queue.is_empty()
    }

    pub fn peek(&self, max: usize) -> Vec<Hash> {
        self.queue.iter().take(max).copied().collect()
    }

    /// Adds one retry candidate and makes the updated bounded FIFO durable.
    /// Returns `false` when the hash was already pending.
    pub fn enqueue(&mut self, hash: Hash) -> Result<bool, PomReproofRecoveryError> {
        if !self.dedup.insert(hash) {
            return Ok(false);
        }
        if self.queue.len() >= POM_REPROOF_BACKLOG_CAP {
            let evicted = self.queue.pop_front().expect("queue is non-empty at capacity");
            self.dedup.remove(&evicted);
        }
        self.queue.push_back(hash);
        self.persist()?;
        Ok(true)
    }

    /// Adds a batch with one durable write. Primarily useful when a bounded
    /// recent-window scan reconstructs multiple gaps after restart.
    pub fn enqueue_batch<I>(&mut self, hashes: I) -> Result<usize, PomReproofRecoveryError>
    where
        I: IntoIterator<Item = Hash>,
    {
        let mut added = 0usize;
        for hash in hashes {
            if !self.dedup.insert(hash) {
                continue;
            }
            if self.queue.len() >= POM_REPROOF_BACKLOG_CAP {
                let evicted = self.queue.pop_front().expect("queue is non-empty at capacity");
                self.dedup.remove(&evicted);
            }
            self.queue.push_back(hash);
            added += 1;
        }
        if added > 0 {
            self.persist()?;
        }
        Ok(added)
    }

    /// Removes a candidate only after the caller has resolved or invalidated the
    /// retry. Returns `false` when the hash was not pending.
    pub fn acknowledge(&mut self, hash: Hash) -> Result<bool, PomReproofRecoveryError> {
        if !self.dedup.remove(&hash) {
            return Ok(false);
        }
        self.queue.retain(|candidate| *candidate != hash);
        self.persist()?;
        Ok(true)
    }

    fn persist(&self) -> Result<(), PomReproofRecoveryError> {
        let snapshot = PomReproofSnapshotV1 { genesis_hash: self.genesis_hash, hashes: self.queue.iter().copied().collect() };
        save_snapshot_atomic(&self.path, &snapshot)
    }
}

fn save_snapshot_atomic(path: &Path, snapshot: &PomReproofSnapshotV1) -> Result<(), PomReproofRecoveryError> {
    snapshot.validate(snapshot.genesis_hash)?;
    let bytes = encode_snapshot(snapshot)?;
    let parent = path.parent().filter(|parent| !parent.as_os_str().is_empty()).unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;

    let temp_path = temporary_path(path, parent);
    let mut temp = OpenOptions::new().write(true).create_new(true).open(&temp_path)?;
    let write_result = (|| -> io::Result<()> {
        temp.write_all(&bytes)?;
        temp.flush()?;
        temp.sync_all()
    })();
    drop(temp);

    if let Err(error) = write_result {
        let _ = fs::remove_file(&temp_path);
        return Err(error.into());
    }
    if let Err(error) = replace_file_atomic(&temp_path, path) {
        let _ = fs::remove_file(&temp_path);
        return Err(error.into());
    }
    sync_parent_directory(parent)?;
    Ok(())
}

fn load_snapshot(path: &Path, expected_genesis: Hash) -> Result<PomReproofSnapshotV1, PomReproofRecoveryError> {
    let snapshot = decode_snapshot(&fs::read(path)?)?;
    snapshot.validate(expected_genesis)?;
    Ok(snapshot)
}

fn encode_snapshot(snapshot: &PomReproofSnapshotV1) -> Result<Vec<u8>, PomReproofRecoveryError> {
    let payload = borsh::to_vec(snapshot).map_err(|error| PomReproofRecoveryError::Decode(error.to_string()))?;
    if payload.len() > MAX_PAYLOAD_BYTES {
        return Err(PomReproofRecoveryError::PayloadTooLarge(payload.len()));
    }
    let payload_len = u32::try_from(payload.len()).map_err(|_| PomReproofRecoveryError::PayloadTooLarge(payload.len()))?;
    let checksum = snapshot_checksum(FORMAT_VERSION, payload_len, &payload);

    let mut bytes = Vec::with_capacity(HEADER_LEN + payload.len());
    bytes.extend_from_slice(&MAGIC);
    bytes.extend_from_slice(&FORMAT_VERSION.to_le_bytes());
    bytes.extend_from_slice(&payload_len.to_le_bytes());
    bytes.extend_from_slice(&checksum);
    bytes.extend_from_slice(&payload);
    Ok(bytes)
}

fn decode_snapshot(bytes: &[u8]) -> Result<PomReproofSnapshotV1, PomReproofRecoveryError> {
    if bytes.len() < HEADER_LEN {
        return Err(PomReproofRecoveryError::TruncatedHeader);
    }
    if bytes[..MAGIC.len()] != MAGIC {
        return Err(PomReproofRecoveryError::InvalidMagic);
    }

    let version_offset = MAGIC.len();
    let version = u16::from_le_bytes(bytes[version_offset..version_offset + size_of::<u16>()].try_into().unwrap());
    if version != FORMAT_VERSION {
        return Err(PomReproofRecoveryError::UnsupportedVersion(version));
    }

    let length_offset = version_offset + size_of::<u16>();
    let payload_len = u32::from_le_bytes(bytes[length_offset..length_offset + size_of::<u32>()].try_into().unwrap()) as usize;
    if payload_len > MAX_PAYLOAD_BYTES {
        return Err(PomReproofRecoveryError::PayloadTooLarge(payload_len));
    }
    let expected_total = HEADER_LEN.checked_add(payload_len).ok_or(PomReproofRecoveryError::PayloadTooLarge(payload_len))?;
    if bytes.len() != expected_total {
        return Err(PomReproofRecoveryError::LengthMismatch { declared: payload_len, actual: bytes.len().saturating_sub(HEADER_LEN) });
    }

    let checksum_offset = length_offset + size_of::<u32>();
    let stored_checksum: [u8; 32] = bytes[checksum_offset..checksum_offset + 32].try_into().unwrap();
    let payload = &bytes[HEADER_LEN..];
    let expected_checksum = snapshot_checksum(version, payload_len as u32, payload);
    if stored_checksum != expected_checksum {
        return Err(PomReproofRecoveryError::ChecksumMismatch);
    }

    borsh::from_slice(payload).map_err(|error| PomReproofRecoveryError::Decode(error.to_string()))
}

fn snapshot_checksum(version: u16, payload_len: u32, payload: &[u8]) -> [u8; 32] {
    let mut state = Params::new().hash_length(32).key(CHECKSUM_KEY).to_state();
    state.update(&MAGIC);
    state.update(&version.to_le_bytes());
    state.update(&payload_len.to_le_bytes());
    state.update(payload);
    let digest = state.finalize();
    let mut checksum = [0u8; 32];
    checksum.copy_from_slice(digest.as_bytes());
    checksum
}

fn temporary_path(target: &Path, parent: &Path) -> PathBuf {
    let file_name = target.file_name().and_then(|name| name.to_str()).unwrap_or(FILE_NAME);
    parent.join(format!(".{file_name}.{}.tmp", Uuid::new_v4()))
}

#[cfg(windows)]
fn replace_file_atomic(replacement: &Path, target: &Path) -> io::Result<()> {
    use std::{ffi::c_void, os::windows::ffi::OsStrExt};

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn ReplaceFileW(
            replaced_file_name: *const u16,
            replacement_file_name: *const u16,
            backup_file_name: *const u16,
            replace_flags: u32,
            exclude: *mut c_void,
            reserved: *mut c_void,
        ) -> i32;
    }

    if !target.exists() {
        return fs::rename(replacement, target);
    }

    let replaced: Vec<u16> = target.as_os_str().encode_wide().chain(std::iter::once(0)).collect();
    let replacement: Vec<u16> = replacement.as_os_str().encode_wide().chain(std::iter::once(0)).collect();
    let result = unsafe {
        ReplaceFileW(replaced.as_ptr(), replacement.as_ptr(), std::ptr::null(), 0, std::ptr::null_mut(), std::ptr::null_mut())
    };
    if result == 0 { Err(io::Error::last_os_error()) } else { Ok(()) }
}

#[cfg(not(windows))]
fn replace_file_atomic(replacement: &Path, target: &Path) -> io::Result<()> {
    fs::rename(replacement, target)
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
    use super::{POM_REPROOF_BACKLOG_CAP, PomReproofRecovery, PomReproofRecoveryError, PomReproofSnapshotV1, encode_snapshot};
    use keryx_hashes::Hash;
    use std::{fs, path::PathBuf};
    use uuid::Uuid;

    fn hash(value: u64) -> Hash {
        let mut bytes = [0u8; 32];
        bytes[..8].copy_from_slice(&value.to_le_bytes());
        Hash::from_bytes(bytes)
    }

    fn test_root() -> PathBuf {
        let root = std::env::temp_dir().join(format!("keryx-ibd-v2-pom-reproof-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        root
    }

    #[test]
    fn new_backlog_is_empty_without_creating_a_snapshot() {
        let root = test_root();
        let recovery = PomReproofRecovery::open(&root, hash(1)).unwrap();
        assert!(recovery.is_empty());
        assert!(!root.join(super::FILE_NAME).exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn pending_candidates_survive_reopen_in_fifo_order() {
        let root = test_root();
        let mut recovery = PomReproofRecovery::open(&root, hash(1)).unwrap();
        assert!(recovery.enqueue(hash(10)).unwrap());
        assert!(recovery.enqueue(hash(11)).unwrap());
        assert!(!recovery.enqueue(hash(10)).unwrap());
        drop(recovery);

        let reopened = PomReproofRecovery::open(&root, hash(1)).unwrap();
        assert_eq!(reopened.peek(10), vec![hash(10), hash(11)]);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn peek_is_crash_safe_and_acknowledge_is_durable() {
        let root = test_root();
        let mut recovery = PomReproofRecovery::open(&root, hash(1)).unwrap();
        recovery.enqueue_batch([hash(10), hash(11)]).unwrap();
        assert_eq!(recovery.peek(1), vec![hash(10)]);
        drop(recovery);

        let mut reopened = PomReproofRecovery::open(&root, hash(1)).unwrap();
        assert_eq!(reopened.peek(2), vec![hash(10), hash(11)]);
        assert!(reopened.acknowledge(hash(10)).unwrap());
        assert!(!reopened.acknowledge(hash(99)).unwrap());
        drop(reopened);

        let reopened = PomReproofRecovery::open(&root, hash(1)).unwrap();
        assert_eq!(reopened.peek(10), vec![hash(11)]);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn backlog_is_bounded_and_evicts_oldest_candidates() {
        let root = test_root();
        let mut recovery = PomReproofRecovery::open(&root, hash(1)).unwrap();
        let count = POM_REPROOF_BACKLOG_CAP + 3;
        assert_eq!(recovery.enqueue_batch((0..count as u64).map(hash)).unwrap(), count);
        assert_eq!(recovery.len(), POM_REPROOF_BACKLOG_CAP);
        assert_eq!(recovery.peek(2), vec![hash(3), hash(4)]);
        drop(recovery);

        let reopened = PomReproofRecovery::open(&root, hash(1)).unwrap();
        assert_eq!(reopened.len(), POM_REPROOF_BACKLOG_CAP);
        assert_eq!(reopened.peek(1), vec![hash(3)]);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn wrong_genesis_is_rejected() {
        let root = test_root();
        let mut recovery = PomReproofRecovery::open(&root, hash(1)).unwrap();
        recovery.enqueue(hash(10)).unwrap();
        drop(recovery);

        assert!(matches!(PomReproofRecovery::open(&root, hash(2)), Err(PomReproofRecoveryError::WrongGenesis { .. })));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn corrupted_snapshot_is_rejected() {
        let root = test_root();
        let mut recovery = PomReproofRecovery::open(&root, hash(1)).unwrap();
        recovery.enqueue(hash(10)).unwrap();
        drop(recovery);

        let path = root.join(super::FILE_NAME);
        let mut bytes = fs::read(&path).unwrap();
        *bytes.last_mut().unwrap() ^= 0x5a;
        fs::write(&path, bytes).unwrap();
        assert!(matches!(PomReproofRecovery::open(&root, hash(1)), Err(PomReproofRecoveryError::ChecksumMismatch)));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn oversized_or_duplicate_snapshots_are_rejected_semantically() {
        let duplicate = PomReproofSnapshotV1 { genesis_hash: hash(1), hashes: vec![hash(9), hash(9)] };
        assert!(matches!(duplicate.validate(hash(1)), Err(PomReproofRecoveryError::DuplicateCandidate)));

        let oversized =
            PomReproofSnapshotV1 { genesis_hash: hash(1), hashes: (0..=POM_REPROOF_BACKLOG_CAP as u64).map(hash).collect() };
        assert!(matches!(oversized.validate(hash(1)), Err(PomReproofRecoveryError::TooManyCandidates(_))));
        assert!(encode_snapshot(&oversized).is_ok());
    }
}
