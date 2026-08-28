$ErrorActionPreference = 'Stop'

$repo = (Get-Location).Path
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-Lf([string]$Path) {
    return ([System.IO.File]::ReadAllText((Join-Path $repo $Path))).Replace("`r`n", "`n")
}

function Write-Lf([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText((Join-Path $repo $Path), $Content, $utf8NoBom)
}

function Replace-Required([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    if (-not $Text.Contains($Old)) {
        throw "Required canonical Phase 3 patch anchor not found: $Label"
    }
    return $Text.Replace($Old, $New)
}

$stageTracking = @'
//! Generic persistent tracking for independent IBD v2 stages.
//!
//! This module implements roadmap Phase 3 only: it records independent stage
//! lifecycle state. It does not make checkpoint metadata a source of consensus
//! truth and it does not implement Phase 5 PoM transport/recovery semantics.
//!
//! Every mutation reloads the latest checkpoint before writing. This prevents a
//! long-lived tracker from overwriting newer UTXO or Service State progress.

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

    /// Explicitly begins a new unit of work for a stage. Headers and body-side
    /// work can legitimately receive a newer target while the pruning point is
    /// unchanged, so an explicit new cycle may reopen a previously committed
    /// stage. The caller must invoke this only immediately before real work.
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

    /// Reconciles an already-durable consensus fact into the checkpoint. This is
    /// intentionally separate from `mark_committed` and must only be used after
    /// consensus itself proves the stage is durable.
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

    /// Records the body-sync target as a reconstruction hint only. Missing bodies
    /// continue to be derived from local consensus state; no persisted missing-body
    /// list is trusted.
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
'@
Write-Lf 'protocol/flows/src/ibd_v2/stage_tracking.rs' ($stageTracking + "`n")

$mod = Read-Lf 'protocol/flows/src/ibd_v2/mod.rs'
$oldMod = @'
pub mod service_state_spool;
pub mod state;
'@
$newMod = @'
pub mod service_state_spool;
pub mod stage_tracking;
pub mod state;
'@
$mod = Replace-Required $mod $oldMod $newMod 'export stage_tracking module'
Write-Lf 'protocol/flows/src/ibd_v2/mod.rs' $mod

$flow = Read-Lf 'protocol/flows/src/ibd/flow.rs'

$oldImports = @'
    ibd_v2::{
        metrics::{StageMetrics, metrics_enabled},
        service_state::ServiceStateWireTracker,
        service_state_recovery::ServiceStateRecovery,
        utxo_recovery::UtxoRecovery,
    },
'@
$newImports = @'
    ibd_v2::{
        metrics::{StageMetrics, metrics_enabled},
        service_state::ServiceStateWireTracker,
        service_state_recovery::ServiceStateRecovery,
        stage_tracking::IbdStageTracker,
        state::Stage,
        utxo_recovery::UtxoRecovery,
    },
'@
$flow = Replace-Required $flow $oldImports $newImports 'flow imports'

$oldHelper = @'
        Self { ctx, router, incoming_route, relay_receiver, body_only_ibd_permitted, header_format, protocol_version }
    }

    async fn start_impl(&mut self) -> Result<(), ProtocolError> {
'@
$newHelper = @'
        Self { ctx, router, incoming_route, relay_receiver, body_only_ibd_permitted, header_format, protocol_version }
    }

    fn stage_tracker(&self, pruning_point: Hash) -> Result<Option<IbdStageTracker>, ProtocolError> {
        if !crate::ibd_v2::enabled_from_env() {
            return Ok(None);
        }
        IbdStageTracker::open(self.ctx.ibd_v2_state_dir(), self.ctx.config.genesis.hash, pruning_point)
            .map(Some)
            .map_err(|err| ProtocolError::OtherOwned(format!("failed to open IBD v2 independent stage tracker: {err}")))
    }

    async fn start_impl(&mut self) -> Result<(), ProtocolError> {
'@
$flow = Replace-Required $flow $oldHelper $newHelper 'stage tracker helper'

$oldSyncStart = @'
            IbdType::Sync { highest_known_syncer_chain_hash, is_utxo_stable, is_pp_anticone_synced } => {
                let pruning_point = session.async_pruning_point().await;

                info!("syncing ahead from current pruning point");
'@
$newSyncStart = @'
            IbdType::Sync { highest_known_syncer_chain_hash, is_utxo_stable, is_pp_anticone_synced } => {
                let pruning_point = session.async_pruning_point().await;
                let stage_tracker = self.stage_tracker(pruning_point)?;
                if let Some(tracker) = &stage_tracker {
                    tracker
                        .reconcile_committed_from_consensus(Stage::Pruning, 1, Some(1))
                        .map_err(|err| ProtocolError::OtherOwned(format!("failed to reconcile IBD v2 Pruning stage: {err}")))?;
                }

                info!("syncing ahead from current pruning point");
'@
$flow = Replace-Required $flow $oldSyncStart $newSyncStart 'normal Sync pruning reconciliation'

$oldSyncHeaders = @'
                // Once utxo is valid, simply sync missing headers
                body_target = self
                    .sync_headers(
                        &session,
                        negotiation_output.syncer_virtual_selected_parent,
                        highest_known_syncer_chain_hash,
                        &relay_block,
                    )
                    .await?;
            }
            IbdType::DownloadHeadersProof => {
'@
$newSyncHeaders = @'
                // Once utxo is valid, simply sync missing headers
                if let Some(tracker) = &stage_tracker {
                    tracker
                        .begin_cycle(Stage::Headers)
                        .map_err(|err| ProtocolError::OtherOwned(format!("failed to begin IBD v2 Headers stage: {err}")))?;
                }
                body_target = self
                    .sync_headers(
                        &session,
                        negotiation_output.syncer_virtual_selected_parent,
                        highest_known_syncer_chain_hash,
                        &relay_block,
                    )
                    .await?;
                if let Some(tracker) = &stage_tracker {
                    tracker
                        .mark_verified(Stage::Headers, 1, Some(1))
                        .and_then(|_| tracker.mark_committed(Stage::Headers, 1, Some(1)))
                        .map_err(|err| ProtocolError::OtherOwned(format!("failed to commit IBD v2 Headers stage: {err}")))?;
                }
            }
            IbdType::DownloadHeadersProof => {
'@
$flow = Replace-Required $flow $oldSyncHeaders $newSyncHeaders 'normal Sync Headers tracking'

$oldHeadersProofStart = @'
            IbdType::DownloadHeadersProof => {
                drop(session); // Avoid holding the previous consensus throughout the staging IBD
                let staging = self.ctx.consensus_manager.new_staging_consensus();
'@
$newHeadersProofStart = @'
            IbdType::DownloadHeadersProof => {
                let stage_tracker = self.stage_tracker(negotiation_output.syncer_pruning_point)?;
                if let Some(tracker) = &stage_tracker {
                    tracker
                        .begin_cycle(Stage::Pruning)
                        .and_then(|_| tracker.begin_cycle(Stage::Headers))
                        .map_err(|err| ProtocolError::OtherOwned(format!("failed to begin IBD v2 headers-proof stages: {err}")))?;
                }
                drop(session); // Avoid holding the previous consensus throughout the staging IBD
                let staging = self.ctx.consensus_manager.new_staging_consensus();
'@
$flow = Replace-Required $flow $oldHeadersProofStart $newHeadersProofStart 'headers-proof begin tracking'

$oldHeadersProofCommit = @'
                    Ok(()) => {
                        spawn_blocking(|| staging.commit()).await.unwrap();
                        info!(
'@
$newHeadersProofCommit = @'
                    Ok(()) => {
                        spawn_blocking(|| staging.commit()).await.unwrap();
                        if let Some(tracker) = &stage_tracker {
                            tracker
                                .reconcile_committed_from_consensus(Stage::Pruning, 1, Some(1))
                                .and_then(|_| tracker.reconcile_committed_from_consensus(Stage::Headers, 1, Some(1)))
                                .map_err(|err| ProtocolError::OtherOwned(format!("failed to reconcile committed IBD v2 headers-proof stages: {err}")))?;
                        }
                        info!(
'@
$flow = Replace-Required $flow $oldHeadersProofCommit $newHeadersProofCommit 'headers-proof committed tracking'

$oldCatchupStart = @'
            IbdType::PruningCatchUp { highest_known_syncer_chain_hash } => {
                info!("catching up to new pruning point {} ", negotiation_output.syncer_pruning_point);
                match self.pruning_point_catchup(&session, &negotiation_output, &relay_block, highest_known_syncer_chain_hash).await {
'@
$newCatchupStart = @'
            IbdType::PruningCatchUp { highest_known_syncer_chain_hash } => {
                let stage_tracker = self.stage_tracker(negotiation_output.syncer_pruning_point)?;
                if let Some(tracker) = &stage_tracker {
                    tracker
                        .begin_cycle(Stage::Pruning)
                        .and_then(|_| tracker.begin_cycle(Stage::Headers))
                        .map_err(|err| ProtocolError::OtherOwned(format!("failed to begin IBD v2 pruning-catchup stages: {err}")))?;
                }
                info!("catching up to new pruning point {} ", negotiation_output.syncer_pruning_point);
                match self.pruning_point_catchup(&session, &negotiation_output, &relay_block, highest_known_syncer_chain_hash).await {
'@
$flow = Replace-Required $flow $oldCatchupStart $newCatchupStart 'pruning catchup begin tracking'

$oldCatchupCommit = @'
                    Ok(()) => {
                        info!("header stage of pruning catchup from peer {} completed", self.router);
'@
$newCatchupCommit = @'
                    Ok(()) => {
                        if let Some(tracker) = &stage_tracker {
                            tracker
                                .reconcile_committed_from_consensus(Stage::Pruning, 1, Some(1))
                                .and_then(|_| tracker.reconcile_committed_from_consensus(Stage::Headers, 1, Some(1)))
                                .map_err(|err| ProtocolError::OtherOwned(format!("failed to reconcile committed IBD v2 pruning-catchup stages: {err}")))?;
                        }
                        info!("header stage of pruning catchup from peer {} completed", self.router);
'@
$flow = Replace-Required $flow $oldCatchupCommit $newCatchupCommit 'pruning catchup committed tracking'

$oldBodies = @'
        // Sync missing bodies in the past of the (possibly ceiling-capped) sync target
        self.sync_missing_block_bodies(&session, body_target).await?;

        // Relay block might be in the antipast of syncer sink, thus check its past for missing bodies
        // as well — but skip it under a sync ceiling (the relay block is the corrupted tip above it).
        if self.sync_ceiling().is_none() {
            self.sync_missing_block_bodies(&session, relay_block.hash()).await?;
        }

        // Following IBD we revalidate orphans since many of them might have been processed during the IBD
'@
$newBodies = @'
        // Phase 3 independent tracking: Bodies and PoM remain distinct lifecycle states even though
        // the current v1.5.5 transport still delivers them through the same block-body pipeline.
        // Phase 5 owns independent PoM persistence/provider semantics.
        let active_pruning_point = session.async_pruning_point().await;
        let body_stage_tracker = self.stage_tracker(active_pruning_point)?;
        if let Some(tracker) = &body_stage_tracker {
            tracker
                .set_body_sync_target(body_target)
                .and_then(|_| tracker.begin_cycle(Stage::Bodies))
                .and_then(|_| tracker.begin_cycle(Stage::Pom))
                .map_err(|err| ProtocolError::OtherOwned(format!("failed to begin IBD v2 Bodies/PoM stages: {err}")))?;
        }

        // Sync missing bodies in the past of the (possibly ceiling-capped) sync target
        self.sync_missing_block_bodies(&session, body_target).await?;

        // Relay block might be in the antipast of syncer sink, thus check its past for missing bodies
        // as well — but skip it under a sync ceiling (the relay block is the corrupted tip above it).
        if self.sync_ceiling().is_none() {
            if let Some(tracker) = &body_stage_tracker {
                tracker
                    .set_body_sync_target(relay_block.hash())
                    .map_err(|err| ProtocolError::OtherOwned(format!("failed to advance IBD v2 body-sync target: {err}")))?;
            }
            self.sync_missing_block_bodies(&session, relay_block.hash()).await?;
        }

        if let Some(tracker) = &body_stage_tracker {
            // Phase 3 can prove the PoM work for this body-sync cycle was
            // validated. Phase 5 owns independent proof persistence and the
            // eventual PoM COMMITTED transition.
            tracker
                .mark_verified(Stage::Pom, 1, Some(1))
                .and_then(|_| tracker.mark_verified(Stage::Bodies, 1, Some(1)))
                .and_then(|_| tracker.mark_committed(Stage::Bodies, 1, Some(1)))
                .map_err(|err| ProtocolError::OtherOwned(format!("failed to finalize IBD v2 Bodies/PoM tracking: {err}")))?;
        }

        // Following IBD we revalidate orphans since many of them might have been processed during the IBD
'@
$flow = Replace-Required $flow $oldBodies $newBodies 'Bodies and PoM independent tracking'

Write-Lf 'protocol/flows/src/ibd/flow.rs' $flow

& rustfmt --edition 2024 --config skip_children=true protocol/flows/src/ibd_v2/stage_tracking.rs protocol/flows/src/ibd_v2/mod.rs protocol/flows/src/ibd/flow.rs
if ($LASTEXITCODE -ne 0) { throw "rustfmt failed with exit code $LASTEXITCODE" }

cargo check -p keryx-p2p-flows --all-targets
if ($LASTEXITCODE -ne 0) { throw "p2p-flows check failed with exit code $LASTEXITCODE" }

cargo check -p keryxd --all-targets
if ($LASTEXITCODE -ne 0) { throw "keryxd integration check failed with exit code $LASTEXITCODE" }

cargo clippy -p keryx-p2p-flows --all-targets --no-deps -- -D warnings -A clippy::collapsible_if
if ($LASTEXITCODE -ne 0) { throw "clippy failed with exit code $LASTEXITCODE" }

cargo test -p keryx-p2p-flows stage_tracking
if ($LASTEXITCODE -ne 0) { throw "stage tracking tests failed with exit code $LASTEXITCODE" }

cargo test -p keryx-p2p-flows service_state_recovery
if ($LASTEXITCODE -ne 0) { throw "Service State regression tests failed with exit code $LASTEXITCODE" }

cargo test -p keryx-p2p-flows utxo_recovery
if ($LASTEXITCODE -ne 0) { throw "UTXO regression tests failed with exit code $LASTEXITCODE" }

Write-Host 'Candidate changes:'
git status --short

git config user.name 'Keryx IBD V2 Local Runner'
git config user.email 'actions@localhost'
git add -- protocol/flows/src/ibd_v2/stage_tracking.rs protocol/flows/src/ibd_v2/mod.rs protocol/flows/src/ibd/flow.rs
if ($LASTEXITCODE -ne 0) { throw 'git add failed' }

$staged = @(git diff --cached --name-only)
$expected = @(
    'protocol/flows/src/ibd/flow.rs',
    'protocol/flows/src/ibd_v2/mod.rs',
    'protocol/flows/src/ibd_v2/stage_tracking.rs'
)
if ($staged.Count -ne $expected.Count) { throw "Unexpected staged file count: $($staged.Count)" }
foreach ($path in $expected) {
    if ($staged -notcontains $path) { throw "Expected staged file missing: $path" }
}

git commit -m 'feat(ibd-v2): track all Phase 3 stages independently'
if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }

git push origin HEAD:ibd-v2-phase3-persistent-state
if ($LASTEXITCODE -ne 0) { throw 'git push failed' }

Write-Host 'Canonical Phase 3 independent stage tracking certified and pushed.'
