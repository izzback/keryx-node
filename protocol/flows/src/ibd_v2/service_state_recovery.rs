//! Durable Service State recovery coordination for IBD v2.
//!
//! The append-only spool is the source of truth for downloaded rows. The small
//! checkpoint may lag the spool if the process dies between the spool fsync and
//! checkpoint replacement, but it must never advertise progress beyond durable
//! spool data.

use super::{
    checkpoint::{CheckpointError, IbdCheckpointV1, load_validated, save_atomic},
    service_state_spool::{ServiceStateSpool, ServiceStateSpoolError},
    state::{ServiceStateResumeMetadata, Stage, StageProgress, StageStatus},
};
use keryx_hashes::Hash;
use std::{
    fs, io,
    path::{Path, PathBuf},
};
use thiserror::Error;

const CHECKPOINT_FILE: &str = "checkpoint.bin";

#[derive(Debug, Error)]
pub enum ServiceStateRecoveryError {
    #[error("IBD v2 recovery I/O error: {0}")]
    Io(#[from] io::Error),
    #[error("IBD v2 checkpoint error: {0}")]
    Checkpoint(#[from] CheckpointError),
    #[error("IBD v2 service-state spool error: {0}")]
    Spool(#[from] ServiceStateSpoolError),
    #[error("IBD v2 checkpoint cursor {checkpoint} is ahead of durable service-state spool cursor {spool}")]
    CheckpointAheadOfSpool { checkpoint: u64, spool: u64 },
    #[error("IBD v2 checkpoint and service-state spool disagree on the row fingerprint at cursor {cursor}")]
    AnchorMismatch { cursor: u64 },
    #[error("IBD v2 service-state operation is invalid while stage is {0:?}")]
    InvalidStage(StageStatus),
}

pub struct ServiceStateRecovery {
    checkpoint_path: PathBuf,
    checkpoint: IbdCheckpointV1,
    spool: ServiceStateSpool,
}

impl ServiceStateRecovery {
    pub fn arm(root: impl AsRef<Path>, genesis_hash: Hash, pruning_point: Hash) -> Result<Self, ServiceStateRecoveryError> {
        let mut recovery = Self::open(root, genesis_hash, pruning_point)?;
        let mut dirty = false;

        let utxo = StageProgress::new(Stage::Utxo).with_status(StageStatus::Committed).with_progress(1, Some(1));
        if recovery.checkpoint.stage(Stage::Utxo) != Some(&utxo) {
            recovery.checkpoint.set_stage(utxo);
            dirty = true;
        }

        if recovery.stage_status() == StageStatus::NotStarted {
            let metadata = recovery.spool.metadata();
            recovery.checkpoint.set_stage(
                StageProgress::new(Stage::ServiceState).with_status(StageStatus::Downloading).with_progress(metadata.row_count, None),
            );
            dirty = true;
        }

        if dirty {
            recovery.persist()?;
        }
        Ok(recovery)
    }

    pub fn open(root: impl AsRef<Path>, genesis_hash: Hash, pruning_point: Hash) -> Result<Self, ServiceStateRecoveryError> {
        let root = root.as_ref();
        fs::create_dir_all(root)?;
        let checkpoint_path = root.join(CHECKPOINT_FILE);
        let spool = ServiceStateSpool::open(service_state_spool_path(root, pruning_point), genesis_hash, pruning_point)?;
        let checkpoint = load_or_new_checkpoint(&checkpoint_path, genesis_hash, pruning_point)?;
        let mut recovery = Self { checkpoint_path, checkpoint, spool };
        recovery.reconcile_from_spool()?;
        Ok(recovery)
    }

    pub fn has_pending(root: impl AsRef<Path>, genesis_hash: Hash, pruning_point: Hash) -> Result<bool, ServiceStateRecoveryError> {
        let path = root.as_ref().join(CHECKPOINT_FILE);
        match load_validated(&path, genesis_hash, Some(pruning_point)) {
            Ok(checkpoint) => Ok(matches!(
                checkpoint.stage(Stage::ServiceState).map(|stage| stage.status),
                Some(StageStatus::Downloading | StageStatus::Verified)
            )),
            Err(CheckpointError::Io(error)) if error.kind() == io::ErrorKind::NotFound => Ok(false),
            Err(CheckpointError::StalePruningPoint { .. }) => Ok(false),
            Err(error) => Err(error.into()),
        }
    }

    pub const fn metadata(&self) -> ServiceStateResumeMetadata {
        self.spool.metadata()
    }

    pub fn is_verified(&self) -> bool {
        self.stage_status() == StageStatus::Verified
    }

    pub fn is_committed(&self) -> bool {
        self.stage_status() == StageStatus::Committed
    }

    pub fn append_chunk(
        &mut self,
        start_cursor: u64,
        next_cursor: u64,
        rows: &[Vec<u8>],
    ) -> Result<ServiceStateResumeMetadata, ServiceStateRecoveryError> {
        if self.stage_status() != StageStatus::Downloading {
            return Err(ServiceStateRecoveryError::InvalidStage(self.stage_status()));
        }

        let metadata = self.spool.append_chunk(start_cursor, next_cursor, rows)?;
        self.checkpoint.service_state = Some(metadata);
        self.checkpoint.set_stage(
            StageProgress::new(Stage::ServiceState).with_status(StageStatus::Downloading).with_progress(metadata.row_count, None),
        );
        self.persist()?;
        Ok(metadata)
    }

    pub fn read_all_rows(&mut self) -> Result<Vec<Vec<u8>>, ServiceStateRecoveryError> {
        Ok(self.spool.read_all_rows()?)
    }

    pub fn mark_verified(&mut self) -> Result<(), ServiceStateRecoveryError> {
        match self.stage_status() {
            StageStatus::Downloading | StageStatus::Verified => {}
            status => return Err(ServiceStateRecoveryError::InvalidStage(status)),
        }
        let metadata = self.spool.metadata();
        self.checkpoint.service_state = Some(metadata);
        self.checkpoint.set_stage(
            StageProgress::new(Stage::ServiceState)
                .with_status(StageStatus::Verified)
                .with_progress(metadata.row_count, Some(metadata.row_count)),
        );
        self.persist()
    }

    pub fn mark_committed(&mut self) -> Result<(), ServiceStateRecoveryError> {
        match self.stage_status() {
            StageStatus::Verified | StageStatus::Committed => {}
            status => return Err(ServiceStateRecoveryError::InvalidStage(status)),
        }
        let metadata = self.spool.metadata();
        self.checkpoint.service_state = Some(metadata);
        self.checkpoint.set_stage(
            StageProgress::new(Stage::ServiceState)
                .with_status(StageStatus::Committed)
                .with_progress(metadata.row_count, Some(metadata.row_count)),
        );
        self.persist()
    }

    fn stage_status(&self) -> StageStatus {
        self.checkpoint.stage(Stage::ServiceState).map(|stage| stage.status).unwrap_or(StageStatus::NotStarted)
    }

    fn reconcile_from_spool(&mut self) -> Result<(), ServiceStateRecoveryError> {
        let durable = self.spool.metadata();
        if let Some(saved) = self.checkpoint.service_state {
            if saved.next_cursor > durable.next_cursor {
                return Err(ServiceStateRecoveryError::CheckpointAheadOfSpool {
                    checkpoint: saved.next_cursor,
                    spool: durable.next_cursor,
                });
            }
            if saved.next_cursor == durable.next_cursor && saved.last_row_fingerprint != durable.last_row_fingerprint {
                return Err(ServiceStateRecoveryError::AnchorMismatch { cursor: durable.next_cursor });
            }
        }

        let mut dirty = self.checkpoint.service_state != Some(durable);
        self.checkpoint.service_state = Some(durable);

        match self.stage_status() {
            StageStatus::NotStarted => {
                self.checkpoint.set_stage(
                    StageProgress::new(Stage::ServiceState)
                        .with_status(StageStatus::Downloading)
                        .with_progress(durable.row_count, None),
                );
                dirty = true;
            }
            StageStatus::Downloading => {
                let expected = StageProgress::new(Stage::ServiceState)
                    .with_status(StageStatus::Downloading)
                    .with_progress(durable.row_count, None);
                if self.checkpoint.stage(Stage::ServiceState) != Some(&expected) {
                    self.checkpoint.set_stage(expected);
                    dirty = true;
                }
            }
            StageStatus::Verified | StageStatus::Committed => {}
        }

        if dirty {
            self.persist()?;
        }
        Ok(())
    }

    fn persist(&mut self) -> Result<(), ServiceStateRecoveryError> {
        self.checkpoint.generation = self.checkpoint.generation.saturating_add(1);
        save_atomic(&self.checkpoint_path, &self.checkpoint)?;
        Ok(())
    }
}

fn load_or_new_checkpoint(path: &Path, genesis_hash: Hash, pruning_point: Hash) -> Result<IbdCheckpointV1, ServiceStateRecoveryError> {
    match load_validated(path, genesis_hash, Some(pruning_point)) {
        Ok(checkpoint) => Ok(checkpoint),
        Err(CheckpointError::Io(error)) if error.kind() == io::ErrorKind::NotFound => {
            Ok(IbdCheckpointV1::new(genesis_hash, pruning_point))
        }
        Err(CheckpointError::StalePruningPoint { .. }) => Ok(IbdCheckpointV1::new(genesis_hash, pruning_point)),
        Err(error) => Err(error.into()),
    }
}

fn service_state_spool_path(root: &Path, pruning_point: Hash) -> PathBuf {
    root.join(format!("service-state-{pruning_point}.spool"))
}

#[cfg(test)]
mod tests {
    use super::{ServiceStateRecovery, ServiceStateRecoveryError, service_state_spool_path};
    use crate::ibd_v2::{
        checkpoint::{load_validated, save_atomic},
        service_state_spool::ServiceStateSpool,
        state::{Stage, StageProgress, StageStatus},
    };
    use keryx_hashes::Hash;
    use std::{fs, path::PathBuf};
    use uuid::Uuid;

    fn hash(byte: u8) -> Hash {
        Hash::from_bytes([byte; 32])
    }

    fn test_root() -> PathBuf {
        let root = std::env::temp_dir().join(format!("keryx-ibd-v2-recovery-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        root
    }

    #[test]
    fn armed_recovery_survives_reopen_and_advances_after_fsync() {
        let root = test_root();
        let mut recovery = ServiceStateRecovery::arm(&root, hash(1), hash(2)).unwrap();
        assert_eq!(recovery.metadata().next_cursor, 0);
        recovery.append_chunk(0, 2, &[b"a".to_vec(), b"b".to_vec()]).unwrap();
        assert!(ServiceStateRecovery::has_pending(&root, hash(1), hash(2)).unwrap());
        drop(recovery);

        let mut reopened = ServiceStateRecovery::open(&root, hash(1), hash(2)).unwrap();
        assert_eq!(reopened.metadata().next_cursor, 2);
        assert_eq!(reopened.read_all_rows().unwrap(), vec![b"a".to_vec(), b"b".to_vec()]);
        drop(reopened);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn checkpoint_lag_is_reconciled_from_durable_spool() {
        let root = test_root();
        let mut recovery = ServiceStateRecovery::arm(&root, hash(1), hash(2)).unwrap();
        recovery.append_chunk(0, 1, &[b"a".to_vec()]).unwrap();
        drop(recovery);

        let mut spool = ServiceStateSpool::open(service_state_spool_path(&root, hash(2)), hash(1), hash(2)).unwrap();
        spool.append_chunk(1, 2, &[b"b".to_vec()]).unwrap();
        drop(spool);

        let recovery = ServiceStateRecovery::open(&root, hash(1), hash(2)).unwrap();
        assert_eq!(recovery.metadata().next_cursor, 2);
        drop(recovery);
        let checkpoint = load_validated(root.join("checkpoint.bin"), hash(1), Some(hash(2))).unwrap();
        assert_eq!(checkpoint.service_state.unwrap().next_cursor, 2);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn checkpoint_is_never_allowed_to_lead_the_spool() {
        let root = test_root();
        let mut recovery = ServiceStateRecovery::arm(&root, hash(1), hash(2)).unwrap();
        recovery.append_chunk(0, 1, &[b"a".to_vec()]).unwrap();
        drop(recovery);

        let path = root.join("checkpoint.bin");
        let mut checkpoint = load_validated(&path, hash(1), Some(hash(2))).unwrap();
        let mut metadata = checkpoint.service_state.unwrap();
        metadata.record_chunk(2, 1, [9; 32]).unwrap();
        checkpoint.service_state = Some(metadata);
        checkpoint.set_stage(StageProgress::new(Stage::ServiceState).with_status(StageStatus::Downloading).with_progress(2, None));
        save_atomic(&path, &checkpoint).unwrap();

        assert!(matches!(
            ServiceStateRecovery::open(&root, hash(1), hash(2)),
            Err(ServiceStateRecoveryError::CheckpointAheadOfSpool { checkpoint: 2, spool: 1 })
        ));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn verified_state_replays_without_network_and_committed_state_is_not_pending() {
        let root = test_root();
        let mut recovery = ServiceStateRecovery::arm(&root, hash(1), hash(2)).unwrap();
        recovery.append_chunk(0, 1, &[b"a".to_vec()]).unwrap();
        recovery.mark_verified().unwrap();
        assert!(recovery.is_verified());
        drop(recovery);
        assert!(ServiceStateRecovery::has_pending(&root, hash(1), hash(2)).unwrap());

        let mut recovery = ServiceStateRecovery::open(&root, hash(1), hash(2)).unwrap();
        assert!(recovery.is_verified());
        recovery.mark_committed().unwrap();
        assert!(recovery.is_committed());
        drop(recovery);
        assert!(!ServiceStateRecovery::has_pending(&root, hash(1), hash(2)).unwrap());
        fs::remove_dir_all(root).unwrap();
    }
}
