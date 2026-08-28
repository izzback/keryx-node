$ErrorActionPreference = 'Stop'

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-Lf([string]$Path) {
    return [System.IO.File]::ReadAllText((Resolve-Path $Path)).Replace("`r`n", "`n")
}

function Write-Lf([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), $utf8NoBom)
}

function Replace-Exact([string]$Path, [string]$Old, [string]$New) {
    $text = Read-Lf $Path
    $oldLf = $Old.Replace("`r`n", "`n")
    $newLf = $New.Replace("`r`n", "`n")
    $first = $text.IndexOf($oldLf, [System.StringComparison]::Ordinal)
    if ($first -lt 0) { throw "Expected text not found in $Path" }
    $second = $text.IndexOf($oldLf, $first + $oldLf.Length, [System.StringComparison]::Ordinal)
    if ($second -ge 0) { throw "Expected text occurs more than once in $Path" }
    $updated = $text.Substring(0, $first) + $newLf + $text.Substring($first + $oldLf.Length)
    Write-Lf $Path $updated
}

function Replace-Between([string]$Path, [string]$StartMarker, [string]$EndMarker, [string]$Replacement) {
    $text = Read-Lf $Path
    $start = $text.IndexOf($StartMarker, [System.StringComparison]::Ordinal)
    if ($start -lt 0) { throw "Start marker not found in $Path" }
    $end = $text.IndexOf($EndMarker, $start, [System.StringComparison]::Ordinal)
    if ($end -lt 0) { throw "End marker not found in $Path" }
    $second = $text.IndexOf($StartMarker, $start + $StartMarker.Length, [System.StringComparison]::Ordinal)
    if ($second -ge 0) { throw "Start marker occurs more than once in $Path" }
    $updated = $text.Substring(0, $start) + $Replacement.Replace("`r`n", "`n") + $text.Substring($end)
    Write-Lf $Path $updated
}

# -----------------------------------------------------------------------------
# FlowContext: carry a production-safe IBD v2 persistence directory from keryxd.
# -----------------------------------------------------------------------------
Replace-Exact 'protocol/flows/src/flow_context.rs' @'
use std::collections::{HashMap, HashSet, VecDeque};
use std::net::IpAddr;
use std::time::Instant;
'@ @'
use std::collections::{HashMap, HashSet, VecDeque};
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::time::Instant;
'@

Replace-Exact 'protocol/flows/src/flow_context.rs' @'
    notification_root: Arc<ConsensusNotificationRoot>,

    // Special sampling logger used only for high-bps networks where logs must be throttled
'@ @'
    notification_root: Arc<ConsensusNotificationRoot>,
    ibd_v2_state_dir: PathBuf,

    // Special sampling logger used only for high-bps networks where logs must be throttled
'@

Replace-Exact 'protocol/flows/src/flow_context.rs' @'
        notification_root: Arc<ConsensusNotificationRoot>,
        hub: Hub,
        mining_rule_engine: Arc<MiningRuleEngine>,
    ) -> Self {
'@ @'
        notification_root: Arc<ConsensusNotificationRoot>,
        hub: Hub,
        mining_rule_engine: Arc<MiningRuleEngine>,
        ibd_v2_state_dir: PathBuf,
    ) -> Self {
'@

Replace-Exact 'protocol/flows/src/flow_context.rs' @'
                tick_service,
                notification_root,
                block_event_logger: Some(BlockEventLogger::new(bps)),
'@ @'
                tick_service,
                notification_root,
                ibd_v2_state_dir,
                block_event_logger: Some(BlockEventLogger::new(bps)),
'@

Replace-Exact 'protocol/flows/src/flow_context.rs' @'
    pub fn max_orphans(&self) -> usize {
        self.max_orphans
    }

    pub fn start_async_services(&self) {
'@ @'
    pub fn max_orphans(&self) -> usize {
        self.max_orphans
    }

    pub fn ibd_v2_state_dir(&self) -> &Path {
        &self.ibd_v2_state_dir
    }

    pub fn start_async_services(&self) {
'@

# -----------------------------------------------------------------------------
# keryxd: keep IBD v2 state under the network datadir so DB reset semantics are
# naturally respected and no temp/current-directory storage is used.
# -----------------------------------------------------------------------------
Replace-Exact 'keryxd/src/daemon.rs' @'
    let app_dir = get_app_dir_from_args(args);
    let db_dir = app_dir.join(network.to_prefixed()).join(DEFAULT_DATA_DIR);
'@ @'
    let app_dir = get_app_dir_from_args(args);
    let db_dir = app_dir.join(network.to_prefixed()).join(DEFAULT_DATA_DIR);
    let ibd_v2_state_dir = db_dir.join("ibd-v2");
'@

Replace-Exact 'keryxd/src/daemon.rs' @'
        notification_root,
        hub.clone(),
        mining_rule_engine.clone(),
    ));
'@ @'
        notification_root,
        hub.clone(),
        mining_rule_engine.clone(),
        ibd_v2_state_dir,
    ));
'@

# -----------------------------------------------------------------------------
# New recovery coordinator. The spool is authoritative for downloaded rows;
# checkpoint metadata is allowed to lag it but can never lead it.
# -----------------------------------------------------------------------------
$recovery = @'
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
    pub fn arm(
        root: impl AsRef<Path>,
        genesis_hash: Hash,
        pruning_point: Hash,
    ) -> Result<Self, ServiceStateRecoveryError> {
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
                StageProgress::new(Stage::ServiceState)
                    .with_status(StageStatus::Downloading)
                    .with_progress(metadata.row_count, None),
            );
            dirty = true;
        }

        if dirty {
            recovery.persist()?;
        }
        Ok(recovery)
    }

    pub fn open(
        root: impl AsRef<Path>,
        genesis_hash: Hash,
        pruning_point: Hash,
    ) -> Result<Self, ServiceStateRecoveryError> {
        let root = root.as_ref();
        fs::create_dir_all(root)?;
        let checkpoint_path = root.join(CHECKPOINT_FILE);
        let spool = ServiceStateSpool::open(service_state_spool_path(root, pruning_point), genesis_hash, pruning_point)?;
        let checkpoint = load_or_new_checkpoint(&checkpoint_path, genesis_hash, pruning_point)?;
        let mut recovery = Self { checkpoint_path, checkpoint, spool };
        recovery.reconcile_from_spool()?;
        Ok(recovery)
    }

    pub fn has_pending(
        root: impl AsRef<Path>,
        genesis_hash: Hash,
        pruning_point: Hash,
    ) -> Result<bool, ServiceStateRecoveryError> {
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
            StageProgress::new(Stage::ServiceState)
                .with_status(StageStatus::Downloading)
                .with_progress(metadata.row_count, None),
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
        self.checkpoint
            .stage(Stage::ServiceState)
            .map(|stage| stage.status)
            .unwrap_or(StageStatus::NotStarted)
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

fn load_or_new_checkpoint(
    path: &Path,
    genesis_hash: Hash,
    pruning_point: Hash,
) -> Result<IbdCheckpointV1, ServiceStateRecoveryError> {
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
        checkpoint.set_stage(
            StageProgress::new(Stage::ServiceState)
                .with_status(StageStatus::Downloading)
                .with_progress(2, None),
        );
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
'@
Write-Lf 'protocol/flows/src/ibd_v2/service_state_recovery.rs' $recovery

Replace-Exact 'protocol/flows/src/ibd_v2/mod.rs' @'
pub mod service_state;
pub mod service_state_spool;
pub mod state;
'@ @'
pub mod service_state;
pub mod service_state_recovery;
pub mod service_state_spool;
pub mod state;
'@

# -----------------------------------------------------------------------------
# IBD flow: arm the Service State checkpoint before UTXO is marked stable, resume
# it when a restart sees stable UTXO + pending Service State, and use the durable
# spool as the transfer source of truth.
# -----------------------------------------------------------------------------
Replace-Exact 'protocol/flows/src/ibd/flow.rs' @'
    ibd_v2::{
        metrics::{StageMetrics, metrics_enabled},
        service_state::ServiceStateWireTracker,
    },
'@ @'
    ibd_v2::{
        metrics::{StageMetrics, metrics_enabled},
        service_state::ServiceStateWireTracker,
        service_state_recovery::ServiceStateRecovery,
    },
'@

Replace-Exact 'protocol/flows/src/ibd/flow.rs' @'
                    self.sync_new_utxo_set(&session, pruning_point, &relay_block.header).await?;
                }
                // Once utxo is valid, simply sync missing headers
'@ @'
                    self.sync_new_utxo_set(&session, pruning_point, &relay_block.header).await?;
                } else if crate::ibd_v2::enabled_from_env()
                    && ServiceStateRecovery::has_pending(
                        self.ctx.ibd_v2_state_dir(),
                        self.ctx.config.genesis.hash,
                        pruning_point,
                    )
                    .map_err(|err| ProtocolError::OtherOwned(format!("failed to inspect IBD v2 service-state recovery: {err}")))?
                {
                    info!("resuming durable service-state download for pruning point {}", pruning_point);
                    self.sync_service_state(&session, pruning_point, &relay_block.header).await?;
                }
                // Once utxo is valid, simply sync missing headers
'@

Replace-Exact 'protocol/flows/src/ibd/flow.rs' @'
        self.sync_pruning_point_utxoset(consensus, pruning_point).await?;
        // Only if the function has reached here, will the utxo be considered "final"
        consensus.async_set_pruning_utxoset_stable().await;
        self.sync_service_state(consensus, pruning_point, relay_header).await?;
'@ @'
        self.sync_pruning_point_utxoset(consensus, pruning_point).await?;
        // Arm Service State recovery before marking UTXO stable. This closes the crash window
        // where a restart could otherwise skip Service State because the UTXO stage already
        // looked complete.
        if crate::ibd_v2::enabled_from_env() {
            let pp_daa = consensus.async_get_header(pruning_point).await?.daa_score;
            if keryx_consensus_core::pom::service_commit_active(pp_daa) {
                drop(
                    ServiceStateRecovery::arm(self.ctx.ibd_v2_state_dir(), self.ctx.config.genesis.hash, pruning_point)
                        .map_err(|err| ProtocolError::OtherOwned(format!("failed to arm IBD v2 service-state recovery: {err}")))?,
                );
            }
        }
        // Only if the UTXO import has reached here will the UTXO stage be considered final.
        consensus.async_set_pruning_utxoset_stable().await;
        self.sync_service_state(consensus, pruning_point, relay_header).await?;
'@

$serviceStateReplacement = @'
    /// Downloads the sealed service-bond state (every finality-flushed row up to the new pruning
    /// point) and verifies its MuHash against `service_state_hash` of the already-validated relay
    /// header before importing. No-op below the H6 gate.
    async fn sync_service_state(
        &mut self,
        consensus: &ConsensusProxy,
        pruning_point: Hash,
        relay_header: &Header,
    ) -> Result<(), ProtocolError> {
        let pp_daa = consensus.async_get_header(pruning_point).await?.daa_score;
        if !keryx_consensus_core::pom::service_commit_active(pp_daa) {
            return Ok(());
        }
        // Peers below v10 ship only rows at or below the pruning point: the handoff band above
        // it would be silently missing, and the fold cannot re-derive it (its cohort windows
        // cross unretained history) — the sync would wedge later instead of failing here.
        if self.protocol_version < 10 {
            return Err(ProtocolError::Other("peer cannot serve the service-state handoff window — sync from an upgraded peer"));
        }
        // The expected commitment lives in headers whose own pruning point is the one we synced:
        // the relay header on the fresh-sync path, the local headers-selected-tip on the
        // recovery path (where the pruning point is the local one, not the syncer's).
        let expected = if relay_header.pruning_point == pruning_point {
            relay_header.service_state_hash
        } else {
            let hst = consensus.async_get_headers_selected_tip().await;
            let hst_header = consensus.async_get_header(hst).await?;
            if hst_header.pruning_point != pruning_point {
                return Err(ProtocolError::Other("no validated header anchors the negotiated pruning point"));
            }
            hst_header.service_state_hash
        };

        let mut recovery = if crate::ibd_v2::enabled_from_env() {
            Some(
                ServiceStateRecovery::open(self.ctx.ibd_v2_state_dir(), self.ctx.config.genesis.hash, pruning_point)
                    .map_err(|err| ProtocolError::OtherOwned(format!("failed to open IBD v2 service-state recovery: {err}")))?,
            )
        } else {
            None
        };

        if recovery.as_ref().is_some_and(ServiceStateRecovery::is_committed) {
            debug!("IBD v2 service state for pruning point {} is already committed", pruning_point);
            return Ok(());
        }

        let verified_replay = recovery.as_ref().is_some_and(ServiceStateRecovery::is_verified);
        let (start_cursor, previous_row_fingerprint) = match recovery.as_ref() {
            Some(recovery) => {
                let metadata = recovery.metadata();
                (Some(metadata.next_cursor), metadata.last_row_fingerprint.map(Vec::from))
            }
            None => (None, None),
        };

        if !verified_replay {
            info!(
                "downloading the sealed service state for pruning point {} from cursor {}",
                pruning_point,
                start_cursor.unwrap_or(0)
            );
            self.router
                .enqueue(make_message!(
                    Payload::RequestServiceState,
                    RequestServiceStateMessage {
                        pruning_point_hash: Some(pruning_point.into()),
                        start_cursor,
                        previous_row_fingerprint,
                    }
                ))
                .await?;
        } else {
            info!("replaying locally verified service-state spool for pruning point {}", pruning_point);
        }

        let handoff_cutoff = pp_daa + keryx_consensus_core::collateral::SERVICE_STATE_HANDOFF_DAA;
        let mut rows: Vec<Vec<u8>> = Vec::new();
        let mut metrics = StageMetrics::new();
        let mut resume_tracker = if verified_replay {
            None
        } else {
            recovery.as_ref().map(|recovery| ServiceStateWireTracker::from_metadata(recovery.metadata()))
        };

        if !verified_replay {
            loop {
                let wait_started = metrics_enabled().then(Instant::now);
                let received = tokio::time::timeout(keryx_p2p_lib::common::DEFAULT_TIMEOUT, self.incoming_route.recv()).await;
                if let Some(wait_started) = wait_started {
                    metrics.record_peer_wait_time(wait_started.elapsed());
                }
                match received {
                    Ok(Some(msg)) => match msg.payload {
                        Some(Payload::ServiceStateChunk(chunk)) => {
                            if let Some(tracker) = &mut resume_tracker {
                                let chunk_pruning_point: Option<Hash> =
                                    chunk.pruning_point_hash.clone().map(TryInto::try_into).transpose()?;
                                tracker
                                    .accept_chunk(chunk_pruning_point, chunk.start_cursor, chunk.next_cursor, &chunk.rows)
                                    .map_err(|err| {
                                        ProtocolError::OtherOwned(format!("invalid IBD v2 service-state chunk metadata: {err:?}"))
                                    })?;
                            }

                            if metrics_enabled() {
                                let chunk_rows = chunk.rows.len() as u64;
                                let chunk_bytes = chunk.rows.iter().map(|row| row.len() as u64).sum();
                                metrics.record_transfer(chunk_rows, chunk_bytes);
                            }

                            let validation_started = metrics_enabled().then(Instant::now);
                            for row in &chunk.rows {
                                let daa = service_row_daa(row).ok_or(ProtocolError::Other("malformed service-state row"))?;
                                if daa > handoff_cutoff {
                                    return Err(ProtocolError::Other("service-state row beyond the handoff ceiling"));
                                }
                            }
                            if let Some(validation_started) = validation_started {
                                metrics.record_validation_time(validation_started.elapsed());
                            }

                            if let Some(recovery) = &mut recovery {
                                let chunk_start = chunk
                                    .start_cursor
                                    .ok_or(ProtocolError::Other("IBD v2 service-state chunk is missing start cursor"))?;
                                let chunk_next = chunk
                                    .next_cursor
                                    .ok_or(ProtocolError::Other("IBD v2 service-state chunk is missing next cursor"))?;
                                let storage_started = metrics_enabled().then(Instant::now);
                                let durable = recovery.append_chunk(chunk_start, chunk_next, &chunk.rows).map_err(|err| {
                                    ProtocolError::OtherOwned(format!("failed to persist IBD v2 service-state chunk: {err}"))
                                })?;
                                if let Some(tracker) = &resume_tracker
                                    && tracker.metadata() != durable
                                {
                                    return Err(ProtocolError::Other(
                                        "IBD v2 service-state wire cursor diverged from durable spool cursor",
                                    ));
                                }
                                if let Some(storage_started) = storage_started {
                                    metrics.record_storage_time(storage_started.elapsed());
                                }
                            } else {
                                rows.extend(chunk.rows);
                            }
                        }
                        Some(Payload::DoneServiceStateChunks(done)) => {
                            if let Some(tracker) = &mut resume_tracker {
                                let done_pruning_point: Option<Hash> = done.pruning_point_hash.map(TryInto::try_into).transpose()?;
                                tracker.accept_done(done_pruning_point, done.next_cursor).map_err(|err| {
                                    ProtocolError::OtherOwned(format!("invalid IBD v2 service-state completion metadata: {err:?}"))
                                })?;
                                if let Some(recovery) = &recovery
                                    && tracker.metadata() != recovery.metadata()
                                {
                                    return Err(ProtocolError::Other(
                                        "IBD v2 service-state completion cursor diverged from durable spool cursor",
                                    ));
                                }
                            }
                            break;
                        }
                        _ => {
                            return Err(ProtocolError::UnexpectedMessage(
                                stringify!(Payload::ServiceStateChunk | Payload::DoneServiceStateChunks),
                                msg.payload.as_ref().map(|v| v.into()),
                            ));
                        }
                    },
                    Ok(None) => return Err(ProtocolError::ConnectionClosed),
                    Err(_) => return Err(ProtocolError::Timeout(keryx_p2p_lib::common::DEFAULT_TIMEOUT)),
                }
            }
        }

        if let Some(tracker) = resume_tracker {
            let checkpoint = tracker.metadata();
            debug!(
                "IBD v2 service-state wire mode={:?} checkpoint_cursor={} checkpoint_chunks={} checkpoint_rows={}",
                tracker.mode(),
                checkpoint.next_cursor,
                checkpoint.chunk_count,
                checkpoint.row_count
            );
        }

        if let Some(recovery) = &mut recovery {
            let storage_started = metrics_enabled().then(Instant::now);
            rows = recovery.read_all_rows().map_err(|err| {
                ProtocolError::OtherOwned(format!("failed to read durable IBD v2 service-state spool: {err}"))
            })?;
            if let Some(storage_started) = storage_started {
                metrics.record_storage_time(storage_started.elapsed());
            }
        }

        // Recompute from the complete durable row stream. This deliberately revalidates every
        // row after a resume so the final MuHash never trusts checkpoint metadata alone.
        let finalize_started = metrics_enabled().then(Instant::now);
        let mut acc = MuHash::new();
        let mut prefix_rows = 0usize;
        for row in &rows {
            let daa = service_row_daa(row).ok_or(ProtocolError::Other("malformed service-state row"))?;
            if daa > handoff_cutoff {
                return Err(ProtocolError::Other("service-state row beyond the handoff ceiling"));
            }
            if daa <= pp_daa {
                acc.add_element(row);
                prefix_rows += 1;
            }
        }
        // Mirror `commitment_at` exactly: no rows seals nothing, and the expected value is then
        // the zero hash.
        let computed = if prefix_rows == 0 { Hash::default() } else { acc.finalize() };
        if let Some(finalize_started) = finalize_started {
            metrics.record_validation_time(finalize_started.elapsed());
        }
        if computed != expected {
            return Err(ProtocolError::OtherOwned(format!(
                "service-state verification failed: peer rows hash to {}, header commits {}",
                computed, expected
            )));
        }

        if let Some(recovery) = &mut recovery {
            recovery
                .mark_verified()
                .map_err(|err| ProtocolError::OtherOwned(format!("failed to checkpoint verified IBD v2 service state: {err}")))?;
        }

        let total_rows = rows.len();
        let handoff_rows = total_rows - prefix_rows;
        let storage_started = metrics_enabled().then(Instant::now);
        consensus.clone().spawn_blocking(move |c| c.import_service_state(rows)).await?;
        if let Some(storage_started) = storage_started {
            metrics.record_storage_time(storage_started.elapsed());
        }

        if let Some(recovery) = &mut recovery {
            recovery
                .mark_committed()
                .map_err(|err| ProtocolError::OtherOwned(format!("failed to commit IBD v2 service-state checkpoint: {err}")))?;
        }

        info!(
            "imported {} sealed service-state rows ({} verified, {} handoff)",
            total_rows, prefix_rows, handoff_rows
        );
        if metrics_enabled() {
            info!(
                "IBD-V2-METRICS: stage=service-state complete=true rows={} downloaded_this_session={} verified={} handoff={} bytes={} elapsed={:.3}s rate={:.2} rows/s throughput={:.2} MB/s peer_wait={:.3}s peer_wait_pct={:.1}% validation={:.3}s storage={:.3}s",
                total_rows,
                metrics.items,
                prefix_rows,
                handoff_rows,
                metrics.bytes,
                metrics.elapsed_seconds(),
                metrics.items_per_second(),
                metrics.megabytes_per_second(),
                metrics.peer_wait_time.as_secs_f64(),
                metrics.peer_wait_ratio() * 100.0,
                metrics.validation_time.as_secs_f64(),
                metrics.storage_time.as_secs_f64()
            );
        }
        Ok(())
    }

'@
Replace-Between 'protocol/flows/src/ibd/flow.rs' '    /// Downloads the sealed service-bond state' '    async fn sync_missing_relay_past_headers' $serviceStateReplacement

# -----------------------------------------------------------------------------
# Expand the dedicated Phase 3 local-runner gate to the newly touched plumbing.
# -----------------------------------------------------------------------------
Replace-Exact '.github/workflows/ibd-v2-phase3-windows.yml' @'
      - 'protocol/flows/src/ibd_v2/**'
      - 'protocol/flows/src/v7/request_service_state.rs'
      - 'protocol/flows/src/lib.rs'
'@ @'
      - 'protocol/flows/src/ibd_v2/**'
      - 'protocol/flows/src/flow_context.rs'
      - 'protocol/flows/src/v7/request_service_state.rs'
      - 'protocol/flows/src/lib.rs'
      - 'keryxd/src/daemon.rs'
'@

Replace-Exact '.github/workflows/ibd-v2-phase3-windows.yml' @'
            (Resolve-Path 'protocol/flows/src/ibd/streams.rs').Path
            (Resolve-Path 'protocol/flows/src/v7/request_service_state.rs').Path
            (Resolve-Path 'protocol/p2p/src/convert/messages.rs').Path
'@ @'
            (Resolve-Path 'protocol/flows/src/ibd/streams.rs').Path
            (Resolve-Path 'protocol/flows/src/flow_context.rs').Path
            (Resolve-Path 'protocol/flows/src/v7/request_service_state.rs').Path
            (Resolve-Path 'protocol/p2p/src/convert/messages.rs').Path
            (Resolve-Path 'keryxd/src/daemon.rs').Path
'@

Replace-Exact '.github/workflows/ibd-v2-phase3-windows.yml' @'
      - name: Check P2P flows crate
        run: cargo check -p keryx-p2p-flows --all-targets

      - name: Clippy P2P flows crate
'@ @'
      - name: Check P2P flows crate
        run: cargo check -p keryx-p2p-flows --all-targets

      - name: Check keryxd integration
        run: cargo check -p keryxd --all-targets

      - name: Clippy P2P flows crate
'@

Write-Host 'Phase 3 Service State resume patch applied successfully.'
