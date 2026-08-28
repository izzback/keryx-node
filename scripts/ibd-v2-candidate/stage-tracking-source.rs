//! Generic persistent tracking for independent IBD v2 stages.
//!
//! This module implements canonical roadmap Phase 3 only: independent lifecycle
//! tracking. It does not make checkpoint metadata a source of consensus truth and
//! it does not implement Phase 5 independent PoM transport/recovery semantics.
//!
//! Every mutation reloads the latest checkpoint before writing so a tracker can
//! never overwrite newer UTXO or Service State progress held in the same file.

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
pub enum StageTrackingError {
    #[error("IBD v2 stage tracking I/O error: {0}")]
    Io(#[from] io::Error),
    #[error("IBD v2 checkpoint error: {0}")]
    Checkpoint(#[from] CheckpointError),
    #[error("invalid IBD v2 {stage:?} stage transition from {from:?} to {to:?}")]
    InvalidTransition { stage: Stage, from: StageStatus, to: StageStatus },
}

#[derive(Debug, Clone)]
pub struct IbdStageTracker {
    checkpoint_path: PathBuf,
    genesis_hash: Hash,
    pruning_point: Hash,
}

impl IbdStageTracker {
    pub fn open(root: impl AsRef<Path>, genesis_hash: Hash, pruning_point: Hash) -> Result<Self, StageTrackingError> {
        let root = root.as_ref();
        fs::create_dir_all(root)?;
        let tracker = Self { checkpoint_path: root.join(CHECKPOINT_FILE), genesis_hash, pruning_point };
        let _ = tracker.load_checkpoint()?;
        Ok(tracker)
    }

    pub fn status(&self, stage: Stage) -> Result<StageStatus, StageTrackingError> {
        Ok(self
            .load_checkpoint()?
            .stage(stage)
            .map(|progress| progress.status)
            .unwrap_or(StageStatus::NotStarted))
    }

    /// Explicitly begins a new unit of work. A stage may legitimately receive a
    /// newer target while the pruning point is unchanged, so an explicit cycle
    /// can reopen a previously committed stage.
    pub fn begin_cycle(&self, stage: Stage) -> Result<(), StageTrackingError> {
        self.write_progress(StageProgress::new(stage).with_status(StageStatus::Downloading))
    }

    pub fn mark_verified(&self, stage: Stage, completed_units: u64, total_units: Option<u64>) -> Result<(), StageTrackingError> {
        let checkpoint = self.load_checkpoint()?;
        let from = checkpoint.stage(stage).map(|progress| progress.status).unwrap_or(StageStatus::NotStarted);
        if !matches!(from, StageStatus::Downloading | StageStatus::Verified) {
            return Err(StageTrackingError::InvalidTransition { stage, from, to: StageStatus::Verified });
        }
        self.write_progress(
            StageProgress::new(stage).with_status(StageStatus::Verified).with_progress(completed_units, total_units),
        )
    }

    pub fn mark_committed(&self, stage: Stage, completed_units: u64, total_units: Option<u64>) -> Result<(), StageTrackingError> {
        let checkpoint = self.load_checkpoint()?;
        let from = checkpoint.stage(stage).map(|progress| progress.status).unwrap_or(StageStatus::NotStarted);
        if !matches!(from, StageStatus::Verified | StageStatus::Committed) {
            return Err(StageTrackingError::InvalidTransition { stage, from, to: StageStatus::Committed });
        }
        self.write_progress(
            StageProgress::new(stage).with_status(StageStatus::Committed).with_progress(completed_units, total_units),
        )
    }

    /// Reconciles a fact already proven durable by local consensus.
    pub fn reconcile_committed_from_consensus(
        &self,
        stage: Stage,
        completed_units: u64,
        total_units: Option<u64>,
    ) -> Result<(), StageTrackingError> {
        self.write_progress(
            StageProgress::new(stage).with_status(StageStatus::Committed).with_progress(completed_units, total_units),
        )
    }

    /// Stores only a reconstructible target hint. Missing bodies are still
    /// recomputed from local consensus state, never trusted from a persisted list.
    pub fn set_body_sync_target(&self, target: Hash) -> Result<(), StageTrackingError> {
        let mut checkpoint = self.load_checkpoint()?;
        if checkpoint.body_sync_target == Some(target) {
            return Ok(());
        }
        checkpoint.body_sync_target = Some(target);
        self.persist(checkpoint)
    }

    fn write_progress(&self, progress: StageProgress) -> Result<(), StageTrackingError> {
        let mut checkpoint = self.load_checkpoint()?;
        if checkpoint.stage(progress.stage) == Some(&progress) {
            return Ok(());
        }
        checkpoint.set_stage(progress);
        self.persist(checkpoint)
    }

    fn persist(&self, mut checkpoint: IbdCheckpointV1) -> Result<(), StageTrackingError> {
        checkpoint.generation = checkpoint.generation.saturating_add(1);
        save_atomic(&self.checkpoint_path, &checkpoint)?;
        Ok(())
    }

    fn load_checkpoint(&self) -> Result<IbdCheckpointV1, StageTrackingError> {
        match load_validated(&self.checkpoint_path, self.genesis_hash, Some(self.pruning_point)) {
            Ok(checkpoint) => Ok(checkpoint),
            Err(CheckpointError::Io(error)) if error.kind() == io::ErrorKind::NotFound => {
                Ok(IbdCheckpointV1::new(self.genesis_hash, self.pruning_point))
            }
            Err(CheckpointError::StalePruningPoint { .. }) => Ok(IbdCheckpointV1::new(self.genesis_hash, self.pruning_point)),
            Err(error) => Err(error.into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{IbdStageTracker, StageTrackingError};
    use crate::ibd_v2::{
        checkpoint::load_validated,
        state::{Stage, StageStatus},
    };
    use keryx_hashes::Hash;
    use std::{fs, path::PathBuf};
    use uuid::Uuid;

    fn hash(byte: u8) -> Hash {
        Hash::from_bytes([byte; 32])
    }

    fn test_root() -> PathBuf {
        let root = std::env::temp_dir().join(format!("keryx-ibd-v2-stage-tracking-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        root
    }

    #[test]
    fn stages_advance_independently_and_survive_reopen() {
        let root = test_root();
        let tracker = IbdStageTracker::open(&root, hash(1), hash(2)).unwrap();
        tracker.reconcile_committed_from_consensus(Stage::Pruning, 1, Some(1)).unwrap();
        tracker.begin_cycle(Stage::Headers).unwrap();
        tracker.mark_verified(Stage::Headers, 1, Some(1)).unwrap();
        tracker.mark_committed(Stage::Headers, 1, Some(1)).unwrap();
        tracker.begin_cycle(Stage::Bodies).unwrap();
        tracker.set_body_sync_target(hash(9)).unwrap();
        drop(tracker);

        let reopened = IbdStageTracker::open(&root, hash(1), hash(2)).unwrap();
        assert_eq!(reopened.status(Stage::Pruning).unwrap(), StageStatus::Committed);
        assert_eq!(reopened.status(Stage::Headers).unwrap(), StageStatus::Committed);
        assert_eq!(reopened.status(Stage::Bodies).unwrap(), StageStatus::Downloading);
        assert_eq!(reopened.status(Stage::Pom).unwrap(), StageStatus::NotStarted);
        assert_eq!(reopened.status(Stage::Utxo).unwrap(), StageStatus::NotStarted);
        assert_eq!(reopened.status(Stage::ServiceState).unwrap(), StageStatus::NotStarted);

        let checkpoint = load_validated(root.join("checkpoint.bin"), hash(1), Some(hash(2))).unwrap();
        assert_eq!(checkpoint.body_sync_target, Some(hash(9)));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn verified_requires_a_downloading_cycle() {
        let root = test_root();
        let tracker = IbdStageTracker::open(&root, hash(1), hash(2)).unwrap();
        assert!(matches!(
            tracker.mark_verified(Stage::Headers, 0, None),
            Err(StageTrackingError::InvalidTransition {
                stage: Stage::Headers,
                from: StageStatus::NotStarted,
                to: StageStatus::Verified
            })
        ));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn committed_stage_can_begin_a_new_explicit_cycle() {
        let root = test_root();
        let tracker = IbdStageTracker::open(&root, hash(1), hash(2)).unwrap();
        tracker.begin_cycle(Stage::Bodies).unwrap();
        tracker.mark_verified(Stage::Bodies, 1, Some(1)).unwrap();
        tracker.mark_committed(Stage::Bodies, 1, Some(1)).unwrap();
        tracker.begin_cycle(Stage::Bodies).unwrap();
        assert_eq!(tracker.status(Stage::Bodies).unwrap(), StageStatus::Downloading);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn stale_pruning_point_resets_independent_stage_tracking() {
        let root = test_root();
        let tracker = IbdStageTracker::open(&root, hash(1), hash(2)).unwrap();
        tracker.begin_cycle(Stage::Pom).unwrap();
        tracker.mark_verified(Stage::Pom, 1, Some(1)).unwrap();
        drop(tracker);

        let tracker = IbdStageTracker::open(&root, hash(1), hash(3)).unwrap();
        assert_eq!(tracker.status(Stage::Pom).unwrap(), StageStatus::NotStarted);
        assert_eq!(tracker.status(Stage::Headers).unwrap(), StageStatus::NotStarted);
        fs::remove_dir_all(root).unwrap();
    }
}
