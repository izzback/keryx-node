//! Durable, versioned IBD v2 checkpoints.
//!
//! A checkpoint is never a substitute for consensus/database truth. It is a
//! crash-recovery hint describing which independently durable IBD work has
//! already been committed and which target/cursor should be resumed next.

use super::state::{ServiceStateResumeMetadata, Stage, StageProgress};
use blake2b_simd::Params;
use borsh::{BorshDeserialize, BorshSerialize};
use keryx_hashes::Hash;
use std::{
    fs::{self, OpenOptions},
    io::{self, Write},
    path::{Path, PathBuf},
};
use thiserror::Error;
use uuid::Uuid;

const MAGIC: [u8; 8] = *b"KXIBDV2\0";
const FORMAT_VERSION: u16 = 1;
const HEADER_LEN: usize = MAGIC.len() + size_of::<u16>() + size_of::<u32>() + 32;
const MAX_PAYLOAD_BYTES: usize = 1024 * 1024;
const CHECKSUM_KEY: &[u8] = b"Keryx-IBD-v2-checkpoint-v1";

#[derive(Debug, Clone, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub struct IbdCheckpointV1 {
    /// Monotonic generation chosen by the checkpoint owner.
    pub generation: u64,
    /// Prevents loading a checkpoint produced for another network.
    pub genesis_hash: Hash,
    /// IBD pruning point all resumable state in this checkpoint is anchored to.
    pub pruning_point: Hash,
    /// Exactly one entry for each [`Stage`].
    pub stages: Vec<StageProgress>,
    /// Durable Service State cursor/fingerprint, when that stage is in progress.
    pub service_state: Option<ServiceStateResumeMetadata>,
    /// High hash used to reconstruct the remaining body set from local consensus.
    pub body_sync_target: Option<Hash>,
}

impl IbdCheckpointV1 {
    pub fn new(genesis_hash: Hash, pruning_point: Hash) -> Self {
        Self {
            generation: 0,
            genesis_hash,
            pruning_point,
            stages: Stage::ALL.into_iter().map(StageProgress::new).collect(),
            service_state: None,
            body_sync_target: None,
        }
    }

    pub fn stage(&self, stage: Stage) -> Option<&StageProgress> {
        self.stages.iter().find(|progress| progress.stage == stage)
    }

    pub fn set_stage(&mut self, progress: StageProgress) {
        if let Some(existing) = self.stages.iter_mut().find(|existing| existing.stage == progress.stage) {
            *existing = progress;
        } else {
            self.stages.push(progress);
        }
    }

    pub fn validate(&self) -> Result<(), CheckpointError> {
        if self.stages.len() != Stage::ALL.len() {
            return Err(CheckpointError::InvalidStageSet);
        }

        for expected_stage in Stage::ALL {
            if self.stages.iter().filter(|progress| progress.stage == expected_stage).count() != 1 {
                return Err(CheckpointError::InvalidStageSet);
            }
        }

        for progress in &self.stages {
            if let Some(total) = progress.total_units
                && progress.completed_units > total
            {
                return Err(CheckpointError::ProgressOutOfRange { stage: progress.stage, completed: progress.completed_units, total });
            }
        }

        if let Some(service_state) = self.service_state {
            if service_state.pruning_point != self.pruning_point {
                return Err(CheckpointError::ServiceStatePruningPointMismatch {
                    checkpoint: self.pruning_point,
                    service_state: service_state.pruning_point,
                });
            }
            if service_state.row_count != service_state.next_cursor {
                return Err(CheckpointError::ServiceStateCursorMismatch {
                    cursor: service_state.next_cursor,
                    rows: service_state.row_count,
                });
            }
            if service_state.next_cursor == 0 && service_state.last_row_fingerprint.is_some() {
                return Err(CheckpointError::InvalidServiceStateAnchor);
            }
            if service_state.next_cursor > 0 && service_state.last_row_fingerprint.is_none() {
                return Err(CheckpointError::InvalidServiceStateAnchor);
            }
        }

        Ok(())
    }

    pub fn validate_for(&self, expected_genesis: Hash, expected_pruning_point: Option<Hash>) -> Result<(), CheckpointError> {
        self.validate()?;
        if self.genesis_hash != expected_genesis {
            return Err(CheckpointError::WrongGenesis { expected: expected_genesis, found: self.genesis_hash });
        }
        if let Some(expected) = expected_pruning_point
            && self.pruning_point != expected
        {
            return Err(CheckpointError::StalePruningPoint { expected, found: self.pruning_point });
        }
        Ok(())
    }
}

#[derive(Debug, Error)]
pub enum CheckpointError {
    #[error("checkpoint I/O error: {0}")]
    Io(#[from] io::Error),
    #[error("checkpoint header is truncated")]
    TruncatedHeader,
    #[error("checkpoint magic is invalid")]
    InvalidMagic,
    #[error("unsupported checkpoint version {0}")]
    UnsupportedVersion(u16),
    #[error("checkpoint payload is too large: {0} bytes")]
    PayloadTooLarge(usize),
    #[error("checkpoint length mismatch: declared {declared} bytes, found {actual} bytes")]
    LengthMismatch { declared: usize, actual: usize },
    #[error("checkpoint checksum mismatch")]
    ChecksumMismatch,
    #[error("checkpoint payload decode failed: {0}")]
    Decode(String),
    #[error("checkpoint does not contain exactly one record for every IBD stage")]
    InvalidStageSet,
    #[error("checkpoint progress for {stage:?} is out of range: {completed} > {total}")]
    ProgressOutOfRange { stage: Stage, completed: u64, total: u64 },
    #[error("service-state pruning point {service_state} does not match checkpoint pruning point {checkpoint}")]
    ServiceStatePruningPointMismatch { checkpoint: Hash, service_state: Hash },
    #[error("service-state cursor {cursor} does not match durable row count {rows}")]
    ServiceStateCursorMismatch { cursor: u64, rows: u64 },
    #[error("service-state cursor/fingerprint anchor is internally inconsistent")]
    InvalidServiceStateAnchor,
    #[error("checkpoint belongs to another network: expected genesis {expected}, found {found}")]
    WrongGenesis { expected: Hash, found: Hash },
    #[error("checkpoint is stale for the current pruning point: expected {expected}, found {found}")]
    StalePruningPoint { expected: Hash, found: Hash },
}

pub fn save_atomic(path: impl AsRef<Path>, checkpoint: &IbdCheckpointV1) -> Result<(), CheckpointError> {
    checkpoint.validate()?;
    let bytes = encode(checkpoint)?;
    let path = path.as_ref();
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

pub fn load(path: impl AsRef<Path>) -> Result<IbdCheckpointV1, CheckpointError> {
    decode(&fs::read(path)?)
}

pub fn load_validated(
    path: impl AsRef<Path>,
    expected_genesis: Hash,
    expected_pruning_point: Option<Hash>,
) -> Result<IbdCheckpointV1, CheckpointError> {
    let checkpoint = load(path)?;
    checkpoint.validate_for(expected_genesis, expected_pruning_point)?;
    Ok(checkpoint)
}

fn encode(checkpoint: &IbdCheckpointV1) -> Result<Vec<u8>, CheckpointError> {
    let payload = borsh::to_vec(checkpoint).map_err(|error| CheckpointError::Decode(error.to_string()))?;
    if payload.len() > MAX_PAYLOAD_BYTES {
        return Err(CheckpointError::PayloadTooLarge(payload.len()));
    }
    let payload_len = u32::try_from(payload.len()).map_err(|_| CheckpointError::PayloadTooLarge(payload.len()))?;
    let checksum = checkpoint_checksum(FORMAT_VERSION, payload_len, &payload);

    let mut bytes = Vec::with_capacity(HEADER_LEN + payload.len());
    bytes.extend_from_slice(&MAGIC);
    bytes.extend_from_slice(&FORMAT_VERSION.to_le_bytes());
    bytes.extend_from_slice(&payload_len.to_le_bytes());
    bytes.extend_from_slice(&checksum);
    bytes.extend_from_slice(&payload);
    Ok(bytes)
}

fn decode(bytes: &[u8]) -> Result<IbdCheckpointV1, CheckpointError> {
    if bytes.len() < HEADER_LEN {
        return Err(CheckpointError::TruncatedHeader);
    }
    if bytes[..MAGIC.len()] != MAGIC {
        return Err(CheckpointError::InvalidMagic);
    }

    let version_offset = MAGIC.len();
    let version = u16::from_le_bytes(bytes[version_offset..version_offset + size_of::<u16>()].try_into().unwrap());
    if version != FORMAT_VERSION {
        return Err(CheckpointError::UnsupportedVersion(version));
    }

    let length_offset = version_offset + size_of::<u16>();
    let payload_len = u32::from_le_bytes(bytes[length_offset..length_offset + size_of::<u32>()].try_into().unwrap()) as usize;
    if payload_len > MAX_PAYLOAD_BYTES {
        return Err(CheckpointError::PayloadTooLarge(payload_len));
    }

    let expected_total = HEADER_LEN.checked_add(payload_len).ok_or(CheckpointError::PayloadTooLarge(payload_len))?;
    if bytes.len() != expected_total {
        return Err(CheckpointError::LengthMismatch { declared: payload_len, actual: bytes.len().saturating_sub(HEADER_LEN) });
    }

    let checksum_offset = length_offset + size_of::<u32>();
    let stored_checksum: [u8; 32] = bytes[checksum_offset..checksum_offset + 32].try_into().unwrap();
    let payload = &bytes[HEADER_LEN..];
    let expected_checksum = checkpoint_checksum(version, payload_len as u32, payload);
    if stored_checksum != expected_checksum {
        return Err(CheckpointError::ChecksumMismatch);
    }

    let checkpoint: IbdCheckpointV1 = borsh::from_slice(payload).map_err(|error| CheckpointError::Decode(error.to_string()))?;
    checkpoint.validate()?;
    Ok(checkpoint)
}

fn checkpoint_checksum(version: u16, payload_len: u32, payload: &[u8]) -> [u8; 32] {
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
    let file_name = target.file_name().and_then(|name| name.to_str()).unwrap_or("ibd-v2.checkpoint");
    parent.join(format!(".{file_name}.{}.tmp", Uuid::new_v4()))
}

#[cfg(windows)]
pub(super) fn replace_file_atomic(replacement: &Path, target: &Path) -> io::Result<()> {
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
pub(super) fn replace_file_atomic(replacement: &Path, target: &Path) -> io::Result<()> {
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
    use super::{CheckpointError, HEADER_LEN, IbdCheckpointV1, load_validated, save_atomic};
    use crate::ibd_v2::state::{ServiceStateResumeMetadata, Stage, StageProgress, StageStatus};
    use keryx_hashes::Hash;
    use std::{fs, path::PathBuf};
    use uuid::Uuid;

    fn hash(byte: u8) -> Hash {
        Hash::from_bytes([byte; 32])
    }

    fn test_path(name: &str) -> PathBuf {
        let directory = std::env::temp_dir().join(format!("keryx-ibd-v2-checkpoint-{}", Uuid::new_v4()));
        fs::create_dir_all(&directory).unwrap();
        directory.join(name)
    }

    fn populated_checkpoint() -> IbdCheckpointV1 {
        let mut checkpoint = IbdCheckpointV1::new(hash(1), hash(2));
        checkpoint.generation = 7;
        checkpoint.set_stage(StageProgress::new(Stage::Headers).with_status(StageStatus::Verified).with_progress(100, Some(100)));
        checkpoint.set_stage(StageProgress::new(Stage::ServiceState).with_status(StageStatus::Downloading).with_progress(10, None));
        checkpoint.body_sync_target = Some(hash(3));
        let mut service_state = ServiceStateResumeMetadata::new(hash(2));
        service_state.record_chunk(10, 10, [9; 32]).unwrap();
        checkpoint.service_state = Some(service_state);
        checkpoint
    }

    #[test]
    fn checkpoint_round_trip_and_atomic_replacement() {
        let path = test_path("checkpoint.bin");
        let checkpoint = populated_checkpoint();
        save_atomic(&path, &checkpoint).unwrap();
        assert_eq!(load_validated(&path, hash(1), Some(hash(2))).unwrap(), checkpoint);

        let mut replacement = checkpoint.clone();
        replacement.generation += 1;
        replacement.set_stage(StageProgress::new(Stage::Bodies).with_status(StageStatus::Downloading).with_progress(42, None));
        save_atomic(&path, &replacement).unwrap();
        assert_eq!(load_validated(&path, hash(1), Some(hash(2))).unwrap(), replacement);

        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn truncated_checkpoint_is_rejected() {
        let path = test_path("truncated.bin");
        save_atomic(&path, &populated_checkpoint()).unwrap();
        let mut bytes = fs::read(&path).unwrap();
        bytes.truncate(bytes.len() - 7);
        fs::write(&path, bytes).unwrap();
        assert!(matches!(load_validated(&path, hash(1), Some(hash(2))), Err(CheckpointError::LengthMismatch { .. })));
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn corrupted_checkpoint_is_rejected() {
        let path = test_path("corrupted.bin");
        save_atomic(&path, &populated_checkpoint()).unwrap();
        let mut bytes = fs::read(&path).unwrap();
        *bytes.last_mut().unwrap() ^= 0x5a;
        fs::write(&path, bytes).unwrap();
        assert!(matches!(load_validated(&path, hash(1), Some(hash(2))), Err(CheckpointError::ChecksumMismatch)));
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn unsupported_version_is_rejected_before_payload_decode() {
        let path = test_path("version.bin");
        save_atomic(&path, &populated_checkpoint()).unwrap();
        let mut bytes = fs::read(&path).unwrap();
        bytes[8..10].copy_from_slice(&2u16.to_le_bytes());
        fs::write(&path, bytes).unwrap();
        assert!(matches!(load_validated(&path, hash(1), Some(hash(2))), Err(CheckpointError::UnsupportedVersion(2))));
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn stale_network_and_pruning_point_are_rejected() {
        let path = test_path("stale.bin");
        save_atomic(&path, &populated_checkpoint()).unwrap();
        assert!(matches!(load_validated(&path, hash(9), Some(hash(2))), Err(CheckpointError::WrongGenesis { .. })));
        assert!(matches!(load_validated(&path, hash(1), Some(hash(9))), Err(CheckpointError::StalePruningPoint { .. })));
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn semantic_corruption_is_rejected_before_write() {
        let path = test_path("semantic.bin");
        let mut checkpoint = populated_checkpoint();
        checkpoint.stages.pop();
        assert!(matches!(save_atomic(&path, &checkpoint), Err(CheckpointError::InvalidStageSet)));
        assert!(!path.exists());
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn short_header_is_rejected() {
        let path = test_path("short.bin");
        fs::write(&path, vec![0u8; HEADER_LEN - 1]).unwrap();
        assert!(matches!(load_validated(&path, hash(1), Some(hash(2))), Err(CheckpointError::TruncatedHeader)));
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }
}
