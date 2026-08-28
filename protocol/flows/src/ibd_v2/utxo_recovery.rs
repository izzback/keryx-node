//! Durable UTXO-stage recovery coordination for IBD v2.
//!
//! The pruning UTXO RocksDB column is the source of truth. The checkpoint only
//! records the stage lifecycle and an informational durable-item count. During a
//! restart, the database is scanned and the checkpoint is reconciled from what
//! is actually durable; progress metadata is never trusted ahead of RocksDB.

use super::{
    checkpoint::{CheckpointError, IbdCheckpointV1, load_validated, save_atomic},
    state::{Stage, StageProgress, StageStatus},
};
use keryx_hashes::Hash;
use std::{
    fs, io,
    path::{Path, PathBuf},
};
use thiserror::Error;

const CHECKPOINT_FILE: &str = "checkpoint.bin";

#[derive(Debug, Error)]
pub enum UtxoRecoveryError {
    #[error("IBD v2 UTXO recovery I/O error: {0}")]
    Io(#[from] io::Error),
    #[error("IBD v2 checkpoint error: {0}")]
    Checkpoint(#[from] CheckpointError),
    #[error("IBD v2 UTXO operation is invalid while stage is {0:?}")]
    InvalidStage(StageStatus),
    #[error("verified UTXO checkpoint records {checkpoint} items but RocksDB contains {database}")]
    VerifiedCountMismatch { checkpoint: u64, database: u64 },
}

pub struct UtxoRecovery {
    checkpoint_path: PathBuf,
    checkpoint: IbdCheckpointV1,
}

impl UtxoRecovery {
    pub fn open(root: impl AsRef<Path>, genesis_hash: Hash, pruning_point: Hash) -> Result<Self, UtxoRecoveryError> {
        let root = root.as_ref();
        fs::create_dir_all(root)?;
        let checkpoint_path = root.join(CHECKPOINT_FILE);
        let checkpoint = load_or_new_checkpoint(&checkpoint_path, genesis_hash, pruning_point)?;
        Ok(Self { checkpoint_path, checkpoint })
    }

    pub fn status(&self) -> StageStatus {
        self.checkpoint.stage(Stage::Utxo).map(|stage| stage.status).unwrap_or(StageStatus::NotStarted)
    }

    pub fn durable_items(&self) -> u64 {
        self.checkpoint.stage(Stage::Utxo).map(|stage| stage.completed_units).unwrap_or(0)
    }

    pub fn should_preserve_partial_db(&self) -> bool {
        matches!(self.status(), StageStatus::Downloading | StageStatus::Verified | StageStatus::Committed)
    }

    pub fn is_verified(&self) -> bool {
        self.status() == StageStatus::Verified
    }

    pub fn is_committed(&self) -> bool {
        self.status() == StageStatus::Committed
    }

    pub fn mark_downloading(&mut self, durable_items: u64) -> Result<(), UtxoRecoveryError> {
        match self.status() {
            StageStatus::NotStarted | StageStatus::Downloading => {}
            status => return Err(UtxoRecoveryError::InvalidStage(status)),
        }
        self.checkpoint
            .set_stage(StageProgress::new(Stage::Utxo).with_status(StageStatus::Downloading).with_progress(durable_items, None));
        self.persist()
    }

    /// Reconcile a lagging Downloading checkpoint from the durable RocksDB set.
    pub fn reconcile_downloading(&mut self, durable_items: u64) -> Result<(), UtxoRecoveryError> {
        if self.status() != StageStatus::Downloading {
            return Err(UtxoRecoveryError::InvalidStage(self.status()));
        }
        if self.durable_items() != durable_items {
            self.checkpoint
                .set_stage(StageProgress::new(Stage::Utxo).with_status(StageStatus::Downloading).with_progress(durable_items, None));
            self.persist()?;
        }
        Ok(())
    }

    pub fn mark_verified(&mut self, durable_items: u64) -> Result<(), UtxoRecoveryError> {
        match self.status() {
            StageStatus::Downloading | StageStatus::Verified => {}
            status => return Err(UtxoRecoveryError::InvalidStage(status)),
        }
        self.checkpoint.set_stage(
            StageProgress::new(Stage::Utxo).with_status(StageStatus::Verified).with_progress(durable_items, Some(durable_items)),
        );
        self.persist()
    }

    pub fn validate_verified_items(&self, database_items: u64) -> Result<(), UtxoRecoveryError> {
        if self.status() != StageStatus::Verified {
            return Err(UtxoRecoveryError::InvalidStage(self.status()));
        }
        let checkpoint_items = self.durable_items();
        if checkpoint_items != database_items {
            return Err(UtxoRecoveryError::VerifiedCountMismatch { checkpoint: checkpoint_items, database: database_items });
        }
        Ok(())
    }

    pub fn mark_committed(&mut self, durable_items: u64) -> Result<(), UtxoRecoveryError> {
        match self.status() {
            StageStatus::Verified | StageStatus::Committed => {}
            status => return Err(UtxoRecoveryError::InvalidStage(status)),
        }
        self.checkpoint.set_stage(
            StageProgress::new(Stage::Utxo).with_status(StageStatus::Committed).with_progress(durable_items, Some(durable_items)),
        );
        self.persist()
    }

    fn persist(&mut self) -> Result<(), UtxoRecoveryError> {
        self.checkpoint.generation = self.checkpoint.generation.saturating_add(1);
        save_atomic(&self.checkpoint_path, &self.checkpoint)?;
        Ok(())
    }
}

fn load_or_new_checkpoint(path: &Path, genesis_hash: Hash, pruning_point: Hash) -> Result<IbdCheckpointV1, UtxoRecoveryError> {
    match load_validated(path, genesis_hash, Some(pruning_point)) {
        Ok(checkpoint) => Ok(checkpoint),
        Err(CheckpointError::Io(error)) if error.kind() == io::ErrorKind::NotFound => {
            Ok(IbdCheckpointV1::new(genesis_hash, pruning_point))
        }
        Err(CheckpointError::StalePruningPoint { .. }) => Ok(IbdCheckpointV1::new(genesis_hash, pruning_point)),
        Err(error) => Err(error.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::{UtxoRecovery, UtxoRecoveryError};
    use crate::ibd_v2::state::StageStatus;
    use keryx_hashes::Hash;
    use std::{fs, path::PathBuf};
    use uuid::Uuid;

    fn hash(byte: u8) -> Hash {
        Hash::from_bytes([byte; 32])
    }

    fn test_root() -> PathBuf {
        let root = std::env::temp_dir().join(format!("keryx-ibd-v2-utxo-recovery-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        root
    }

    #[test]
    fn downloading_progress_reconciles_and_survives_reopen() {
        let root = test_root();
        let mut recovery = UtxoRecovery::open(&root, hash(1), hash(2)).unwrap();
        assert_eq!(recovery.status(), StageStatus::NotStarted);
        recovery.mark_downloading(0).unwrap();
        recovery.reconcile_downloading(123).unwrap();
        drop(recovery);

        let recovery = UtxoRecovery::open(&root, hash(1), hash(2)).unwrap();
        assert_eq!(recovery.status(), StageStatus::Downloading);
        assert_eq!(recovery.durable_items(), 123);
        assert!(recovery.should_preserve_partial_db());
        drop(recovery);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn verified_and_committed_transitions_are_durable() {
        let root = test_root();
        let mut recovery = UtxoRecovery::open(&root, hash(1), hash(2)).unwrap();
        recovery.mark_downloading(0).unwrap();
        recovery.reconcile_downloading(77).unwrap();
        recovery.mark_verified(77).unwrap();
        recovery.validate_verified_items(77).unwrap();
        assert!(matches!(
            recovery.validate_verified_items(76),
            Err(UtxoRecoveryError::VerifiedCountMismatch { checkpoint: 77, database: 76 })
        ));
        recovery.mark_committed(77).unwrap();
        drop(recovery);

        let recovery = UtxoRecovery::open(&root, hash(1), hash(2)).unwrap();
        assert!(recovery.is_committed());
        assert_eq!(recovery.durable_items(), 77);
        drop(recovery);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn stale_pruning_point_starts_a_fresh_utxo_stage() {
        let root = test_root();
        let mut recovery = UtxoRecovery::open(&root, hash(1), hash(2)).unwrap();
        recovery.mark_downloading(12).unwrap();
        drop(recovery);

        let recovery = UtxoRecovery::open(&root, hash(1), hash(3)).unwrap();
        assert_eq!(recovery.status(), StageStatus::NotStarted);
        assert_eq!(recovery.durable_items(), 0);
        drop(recovery);
        fs::remove_dir_all(root).unwrap();
    }
}
