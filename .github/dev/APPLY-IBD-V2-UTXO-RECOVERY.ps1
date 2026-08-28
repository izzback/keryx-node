[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Read-Lf([string]$Path) {
    return [IO.File]::ReadAllText((Resolve-Path $Path)).Replace("`r`n", "`n")
}

function Write-Lf([string]$Path, [string]$Text) {
    $full = if (Test-Path $Path) { (Resolve-Path $Path).Path } else { [IO.Path]::GetFullPath((Join-Path $PWD $Path)) }
    $parent = Split-Path -Parent $full
    if ($parent -and !(Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($full, $Text.Replace("`r`n", "`n"), $utf8)
}

function Replace-Once([string]$Path, [string]$Needle, [string]$Replacement) {
    $text = Read-Lf $Path
    $needleLf = $Needle.Replace("`r`n", "`n")
    $replacementLf = $Replacement.Replace("`r`n", "`n")
    $first = $text.IndexOf($needleLf, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "Patch anchor not found in $Path" }
    if ($text.IndexOf($needleLf, $first + $needleLf.Length, [StringComparison]::Ordinal) -ge 0) {
        throw "Patch anchor is not unique in $Path"
    }
    $text = $text.Substring(0, $first) + $replacementLf + $text.Substring($first + $needleLf.Length)
    Write-Lf $Path $text
}

function Replace-Between([string]$Path, [string]$StartMarker, [string]$EndMarker, [string]$Replacement) {
    $text = Read-Lf $Path
    $start = $text.IndexOf($StartMarker, [StringComparison]::Ordinal)
    if ($start -lt 0) { throw "Start marker not found in $Path: $StartMarker" }
    $end = $text.IndexOf($EndMarker, $start + $StartMarker.Length, [StringComparison]::Ordinal)
    if ($end -lt 0) { throw "End marker not found in $Path: $EndMarker" }
    $text = $text.Substring(0, $start) + $Replacement.Replace("`r`n", "`n") + $text.Substring($end)
    Write-Lf $Path $text
}

Write-Host 'Installing protoc 29.6 and Rust 1.93.0 for UTXO recovery certification...'
$protocVersion = '29.6'
$protocArchive = Join-Path $env:RUNNER_TEMP "protoc-$protocVersion-win64.zip"
$protocRoot = Join-Path $env:RUNNER_TEMP "protoc-$protocVersion-utxo"
if (Test-Path $protocRoot) { Remove-Item $protocRoot -Recurse -Force }
New-Item -ItemType Directory -Path $protocRoot -Force | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/protocolbuffers/protobuf/releases/download/v$protocVersion/protoc-$protocVersion-win64.zip" -OutFile $protocArchive
Expand-Archive -LiteralPath $protocArchive -DestinationPath $protocRoot -Force
$protocBin = Join-Path $protocRoot 'bin'
$env:PATH = "$protocBin;$env:PATH"
& (Join-Path $protocBin 'protoc.exe') --version
if ($LASTEXITCODE -ne 0) { throw 'protoc install failed' }

$rustRoot = Join-Path $env:RUNNER_TEMP 'rust-1.93.0-utxo'
$cargoHome = Join-Path $rustRoot 'cargo'
$rustupHome = Join-Path $rustRoot 'rustup'
$rustupInit = Join-Path $env:RUNNER_TEMP 'rustup-init-utxo.exe'
New-Item -ItemType Directory -Path $rustRoot -Force | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe' -OutFile $rustupInit
$env:CARGO_HOME = $cargoHome
$env:RUSTUP_HOME = $rustupHome
& $rustupInit -y --no-modify-path --profile minimal --default-host x86_64-pc-windows-msvc --default-toolchain 1.93.0
if ($LASTEXITCODE -ne 0) { throw 'rustup-init failed' }
$cargoBin = Join-Path $cargoHome 'bin'
$env:PATH = "$cargoBin;$env:PATH"
& (Join-Path $cargoBin 'rustup.exe') component add rustfmt clippy --toolchain 1.93.0-x86_64-pc-windows-msvc
if ($LASTEXITCODE -ne 0) { throw 'rust component install failed' }

Write-Host 'Creating durable UTXO recovery coordinator...'
Write-Lf 'protocol/flows/src/ibd_v2/utxo_recovery.rs' @'
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
        self.checkpoint.set_stage(
            StageProgress::new(Stage::Utxo).with_status(StageStatus::Downloading).with_progress(durable_items, None),
        );
        self.persist()
    }

    /// Reconcile a lagging Downloading checkpoint from the durable RocksDB set.
    pub fn reconcile_downloading(&mut self, durable_items: u64) -> Result<(), UtxoRecoveryError> {
        if self.status() != StageStatus::Downloading {
            return Err(UtxoRecoveryError::InvalidStage(self.status()));
        }
        if self.durable_items() != durable_items {
            self.checkpoint.set_stage(
                StageProgress::new(Stage::Utxo).with_status(StageStatus::Downloading).with_progress(durable_items, None),
            );
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
            StageProgress::new(Stage::Utxo)
                .with_status(StageStatus::Verified)
                .with_progress(durable_items, Some(durable_items)),
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
            StageProgress::new(Stage::Utxo)
                .with_status(StageStatus::Committed)
                .with_progress(durable_items, Some(durable_items)),
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
'@

Replace-Once 'protocol/flows/src/ibd_v2/mod.rs' @'
pub mod state;
'@ @'
pub mod state;
pub mod utxo_recovery;
'@

Write-Host 'Making each imported UTXO network chunk atomic in RocksDB...'
Replace-Once 'consensus/src/model/stores/utxo_set.rs' @'
    fn write_many(&mut self, utxos: &[(TransactionOutpoint, UtxoEntry)]) -> Result<(), StoreError> {
        let mut writer = DirectDbWriter::new(&self.db);
        self.access.write_many(&mut writer, &mut utxos.iter().map(|(o, e)| ((*o).into(), Arc::new(e.clone()))))?;
        Ok(())
    }
'@ @'
    fn write_many(&mut self, utxos: &[(TransactionOutpoint, UtxoEntry)]) -> Result<(), StoreError> {
        // Imported IBD chunks must be all-or-nothing. DirectDbWriter performs one RocksDB
        // put per key, so a hard process loss can otherwise leave half a network chunk on
        // disk. A single WriteBatch gives recovery a clean durable-prefix boundary.
        let mut batch = WriteBatch::default();
        {
            let mut writer = BatchDbWriter::new(&mut batch);
            self.access.write_many(&mut writer, &mut utxos.iter().map(|(o, e)| ((*o).into(), Arc::new(e.clone()))))?;
        }
        self.db.write(batch)?;
        Ok(())
    }
'@

Write-Host 'Preserving the real UTXO count when Service State arms its checkpoint...'
Replace-Once 'protocol/flows/src/ibd_v2/service_state_recovery.rs' @'
        let utxo = StageProgress::new(Stage::Utxo).with_status(StageStatus::Committed).with_progress(1, Some(1));
        if recovery.checkpoint.stage(Stage::Utxo) != Some(&utxo) {
'@ @'
        let durable_utxos = recovery
            .checkpoint
            .stage(Stage::Utxo)
            .map(|stage| stage.completed_units)
            .filter(|count| *count > 0)
            .unwrap_or(1);
        let utxo = StageProgress::new(Stage::Utxo)
            .with_status(StageStatus::Committed)
            .with_progress(durable_utxos, Some(durable_utxos));
        if recovery.checkpoint.stage(Stage::Utxo) != Some(&utxo) {
'@

Write-Host 'Wiring UTXO recovery into the IBD flow...'
Replace-Once 'protocol/flows/src/ibd/flow.rs' @'
        service_state::ServiceStateWireTracker,
        service_state_recovery::ServiceStateRecovery,
'@ @'
        service_state::ServiceStateWireTracker,
        service_state_recovery::ServiceStateRecovery,
        utxo_recovery::UtxoRecovery,
'@
Replace-Once 'protocol/flows/src/ibd/flow.rs' @'
    header::Header,
    pom::PomProof,
'@ @'
    header::Header,
    muhash::MuHashExtensions,
    pom::PomProof,
'@
Replace-Once 'protocol/flows/src/ibd/flow.rs' @'
    trusted::TrustedBlock,
    tx::Transaction,
'@ @'
    trusted::TrustedBlock,
    tx::{Transaction, TransactionOutpoint, UtxoEntry},
'@

Replace-Between 'protocol/flows/src/ibd/flow.rs' '    async fn sync_new_utxo_set(' '    /// Downloads the sealed service-bond state' @'
    async fn sync_new_utxo_set(
        &mut self,
        consensus: &ConsensusProxy,
        pruning_point: Hash,
        relay_header: &Header,
    ) -> Result<(), ProtocolError> {
        let mut recovery = if crate::ibd_v2::enabled_from_env() {
            Some(
                UtxoRecovery::open(self.ctx.ibd_v2_state_dir(), self.ctx.config.genesis.hash, pruning_point)
                    .map_err(|err| ProtocolError::OtherOwned(format!("failed to open IBD v2 UTXO recovery: {err}")))?,
            )
        } else {
            None
        };

        let already_committed = recovery.as_ref().is_some_and(UtxoRecovery::is_committed);
        if already_committed {
            info!("IBD v2 UTXO set for pruning point {} is already committed; skipping network replay", pruning_point);
        } else {
            let preserve_partial = recovery.as_ref().is_some_and(UtxoRecovery::should_preserve_partial_db);
            if preserve_partial {
                info!("IBD v2 preserving partial pruning UTXO RocksDB state for {}", pruning_point);
            } else {
                // Fresh target (or legacy IBD): first invalidate/clear the old pruning UTXO set.
                // If a process dies during the clear, the checkpoint is still NotStarted and the
                // next boot safely repeats the idempotent clear before any partial DB is trusted.
                consensus.async_clear_pruning_utxo_set().await;
                crate::ibd_v2::fault_injection::crash_if_requested("utxo-after-clear");
                if let Some(recovery) = &mut recovery {
                    recovery
                        .mark_downloading(0)
                        .map_err(|err| ProtocolError::OtherOwned(format!("failed to arm IBD v2 UTXO recovery: {err}")))?;
                    crate::ibd_v2::fault_injection::crash_if_requested("utxo-after-checkpoint");
                }
            }

            self.sync_pruning_point_utxoset(consensus, pruning_point, recovery.as_mut()).await?;
        }

        // Arm Service State before exposing the UTXO stage as stable. A crash after UTXO commit
        // but before this point therefore re-enters sync_new_utxo_set, observes the committed
        // UTXO checkpoint, skips the network, and arms Service State before setting stability.
        if crate::ibd_v2::enabled_from_env() {
            let pp_daa = consensus.async_get_header(pruning_point).await?.daa_score;
            if keryx_consensus_core::pom::service_commit_active(pp_daa) {
                drop(
                    ServiceStateRecovery::arm(self.ctx.ibd_v2_state_dir(), self.ctx.config.genesis.hash, pruning_point)
                        .map_err(|err| ProtocolError::OtherOwned(format!("failed to arm IBD v2 service-state recovery: {err}")))?,
                );
            }
        }
        consensus.async_set_pruning_utxoset_stable().await;
        self.sync_service_state(consensus, pruning_point, relay_header).await?;
        // Once a new utxoset is stored, the utxoindex needs to be resynced as well. This happens through the reset handler mechanism.
        let consensus_manager = self.ctx.consensus_manager.clone();
        spawn_blocking(move || consensus_manager.invoke_consensus_reset_handlers()).await.unwrap();
        self.ctx.on_pruning_point_utxoset_override();
        Ok(())
    }

'@

Replace-Between 'protocol/flows/src/ibd/flow.rs' '    async fn sync_pruning_point_utxoset(' '    async fn sync_missing_trusted_bodies(' @'
    async fn rebuild_durable_pruning_utxo_state(
        &self,
        consensus: &ConsensusProxy,
        pruning_point: Hash,
    ) -> Result<(MuHash, u64, Option<(TransactionOutpoint, UtxoEntry)>), ProtocolError> {
        const SCAN_CHUNK: usize = 50_000;
        let coin_age_activation = self.ctx.config.params.coin_age_activation;
        let mut multiset = MuHash::new();
        let mut items = 0u64;
        let mut from_outpoint = None;
        let mut skip_first = false;
        let mut last = None;

        loop {
            let chunk = consensus
                .async_get_pruning_point_utxos(pruning_point, from_outpoint, SCAN_CHUNK, skip_first)
                .await?;
            if chunk.is_empty() {
                break;
            }

            for (outpoint, entry) in &chunk {
                let element = MuHash::from_utxo(outpoint, entry, coin_age_activation);
                multiset.combine(&element);
            }
            items = items.saturating_add(chunk.len() as u64);
            last = chunk.last().cloned();
            from_outpoint = last.as_ref().map(|(outpoint, _)| *outpoint);
            skip_first = true;
        }

        Ok((multiset, items, last))
    }

    async fn sync_pruning_point_utxoset(
        &mut self,
        consensus: &ConsensusProxy,
        pruning_point: Hash,
        mut recovery: Option<&mut UtxoRecovery>,
    ) -> Result<(), ProtocolError> {
        info!("downloading the pruning point utxoset, this can take a little while.");

        let verified_replay = recovery.as_deref().is_some_and(UtxoRecovery::is_verified);
        let preserve_partial = recovery.as_deref().is_some_and(UtxoRecovery::should_preserve_partial_db);
        let (mut multiset, mut durable_items, durable_anchor) = if preserve_partial {
            let rebuilt = self.rebuild_durable_pruning_utxo_state(consensus, pruning_point).await?;
            info!(
                "IBD v2 reconstructed {} durable pruning UTXOs from RocksDB{}",
                rebuilt.1,
                if verified_replay { " for verified local replay" } else { " before network resume" }
            );
            if let Some(recovery) = recovery.as_deref_mut() {
                if verified_replay {
                    recovery
                        .validate_verified_items(rebuilt.1)
                        .map_err(|err| ProtocolError::OtherOwned(format!("invalid verified IBD v2 UTXO recovery state: {err}")))?;
                } else {
                    recovery
                        .reconcile_downloading(rebuilt.1)
                        .map_err(|err| ProtocolError::OtherOwned(format!("failed to reconcile IBD v2 UTXO checkpoint: {err}")))?;
                }
            }
            rebuilt
        } else {
            (MuHash::new(), 0, None)
        };

        let reused_utxos = durable_items;
        let processing_started = metrics_enabled().then(Instant::now);
        let mut network_chunks = 0u64;
        let mut network_utxos = 0u64;
        let mut appended_utxos = 0u64;
        let mut append_time = Duration::ZERO;

        if !verified_replay {
            self.router
                .enqueue(make_message!(
                    Payload::RequestPruningPointUtxoSet,
                    RequestPruningPointUtxoSetMessage { pruning_point_hash: Some(pruning_point.into()) }
                ))
                .await?;
            let mut chunk_stream = PruningPointUtxosetChunkStream::new(&self.router, &mut self.incoming_route);
            let mut anchor_seen = durable_anchor.is_none();

            while let Some(mut chunk) = chunk_stream.next().await? {
                network_chunks = network_chunks.saturating_add(1);
                network_utxos = network_utxos.saturating_add(chunk.len() as u64);

                // Peers v1.5.5 cannot start the UTXO stream at an arbitrary cursor. During a
                // recovery they therefore resend the prefix. Drain it without touching RocksDB
                // until we encounter the exact last durable outpoint. The final commitment check
                // still cryptographically validates the union of old durable prefix + new suffix.
                if !anchor_seen {
                    let (anchor_outpoint, anchor_entry) = durable_anchor.as_ref().expect("anchor exists when not yet seen");
                    if let Some(position) = chunk.iter().position(|(outpoint, _)| outpoint == anchor_outpoint) {
                        if &chunk[position].1 != anchor_entry {
                            return Err(ProtocolError::Other("IBD v2 UTXO resume anchor value differs from durable RocksDB entry"));
                        }
                        anchor_seen = true;
                        chunk.drain(..=position);
                    } else {
                        continue;
                    }
                }

                if chunk.is_empty() {
                    continue;
                }

                let appended = chunk.len() as u64;
                let append_started = metrics_enabled().then(Instant::now);
                multiset = consensus
                    .clone()
                    .spawn_blocking(move |c| {
                        c.append_imported_pruning_point_utxos(&chunk, &mut multiset);
                        multiset
                    })
                    .await;
                if let Some(append_started) = append_started {
                    append_time = append_time.saturating_add(append_started.elapsed());
                }

                // write_many() is a single RocksDB WriteBatch in IBD v2, so this point is a
                // complete durable-prefix boundary even under std::process::abort().
                durable_items = durable_items.saturating_add(appended);
                appended_utxos = appended_utxos.saturating_add(appended);
                crate::ibd_v2::fault_injection::crash_if_requested("utxo-after-chunk-commit");
                if let Some(recovery) = recovery.as_deref_mut() {
                    recovery
                        .reconcile_downloading(durable_items)
                        .map_err(|err| ProtocolError::OtherOwned(format!("failed to checkpoint IBD v2 UTXO progress: {err}")))?;
                }
            }

            if !anchor_seen {
                return Err(ProtocolError::Other("peer UTXO stream ended before the durable IBD v2 resume anchor"));
            }

            if let Some(recovery) = recovery.as_deref_mut() {
                recovery
                    .mark_verified(durable_items)
                    .map_err(|err| ProtocolError::OtherOwned(format!("failed to checkpoint verified IBD v2 UTXO set: {err}")))?;
            }
            crate::ibd_v2::fault_injection::crash_if_requested("utxo-after-verified");
        }

        let import_started = metrics_enabled().then(Instant::now);
        consensus.clone().spawn_blocking(move |c| c.import_pruning_point_utxo_set(pruning_point, multiset)).await?;
        let import_time = import_started.map(|started| started.elapsed()).unwrap_or(Duration::ZERO);
        crate::ibd_v2::fault_injection::crash_if_requested("utxo-after-import");

        if let Some(recovery) = recovery.as_deref_mut() {
            recovery
                .mark_committed(durable_items)
                .map_err(|err| ProtocolError::OtherOwned(format!("failed to commit IBD v2 UTXO checkpoint: {err}")))?;
        }

        if metrics_enabled() {
            let elapsed = processing_started.expect("metrics start is present when metrics are enabled").elapsed();
            let elapsed_seconds = elapsed.as_secs_f64();
            let processing_time = append_time.saturating_add(import_time);
            let processing_ratio =
                if elapsed_seconds == 0.0 { 0.0 } else { (processing_time.as_secs_f64() / elapsed_seconds).clamp(0.0, 1.0) };
            let utxos_per_second = if elapsed_seconds == 0.0 { 0.0 } else { appended_utxos as f64 / elapsed_seconds };
            let average_append_ms =
                if network_chunks == 0 { 0.0 } else { append_time.as_secs_f64() * 1000.0 / network_chunks as f64 };
            info!(
                "IBD-V2-METRICS: stage=utxo-processing complete=true chunks={} utxos={} reused={} network_received={} appended={} elapsed={:.3}s rate={:.2} appended_utxos/s append={:.3}s avg_append={:.3}ms/network-chunk final_import={:.3}s processing_pct={:.1}%",
                network_chunks,
                durable_items,
                reused_utxos,
                network_utxos,
                appended_utxos,
                elapsed_seconds,
                utxos_per_second,
                append_time.as_secs_f64(),
                average_append_ms,
                import_time.as_secs_f64(),
                processing_ratio * 100.0
            );
        }
        Ok(())
    }

'@

Write-Host 'Creating UTXO hard-crash test scripts...'
Write-Lf 'scripts/ibd-v2/phase3/START-UTXO-CRASH-TEST.ps1' @'
[CmdletBinding()]
param(
    [ValidateSet('utxo-after-clear','utxo-after-checkpoint','utxo-after-chunk-commit','utxo-after-verified','utxo-after-import')]
    [string]$FaultPoint = 'utxo-after-chunk-commit',
    [string]$NodePath = (Join-Path $PSScriptRoot 'keryxd.exe'),
    [string]$DataDir = 'E:\datanode\keryx-ibd-v2-utxo-realtest',
    [string]$ResultsRoot = (Join-Path $PSScriptRoot 'results-utxo')
)
$ErrorActionPreference = 'Stop'
if (!(Test-Path -LiteralPath $NodePath -PathType Leaf)) { throw "Node not found: $NodePath" }
if (Get-Process -Name keryxd -ErrorAction SilentlyContinue) { throw 'Another keryxd process is already running. Stop it first.' }
if (Test-Path -LiteralPath $DataDir) {
    if (Get-ChildItem -LiteralPath $DataDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1) {
        throw "Crash-test datadir is not empty: $DataDir"
    }
} else { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
New-Item -ItemType Directory -Path $ResultsRoot -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$resultDir = Join-Path $ResultsRoot "crash-$FaultPoint-$stamp"
New-Item -ItemType Directory -Path $resultDir -Force | Out-Null
$stdout = Join-Path $resultDir 'node.stdout.log'
$stderr = Join-Path $resultDir 'node.stderr.log'
@("fault_point=$FaultPoint","datadir=$DataDir","node=$NodePath","started_utc=$([DateTime]::UtcNow.ToString('o'))") | Set-Content -Encoding ASCII (Join-Path $resultDir 'TEST-METADATA.txt')
$old = @{
    Ibd = $env:KERYX_IBD_V2
    Metrics = $env:KERYX_IBD_V2_METRICS
    Fault = $env:KERYX_IBD_V2_FAULT_INJECTION
    Point = $env:KERYX_IBD_V2_FAULT_POINT
}
try {
    $env:KERYX_IBD_V2 = '1'
    $env:KERYX_IBD_V2_METRICS = '1'
    $env:KERYX_IBD_V2_FAULT_INJECTION = '1'
    $env:KERYX_IBD_V2_FAULT_POINT = $FaultPoint
    Write-Host "Starting UTXO hard-crash test at $FaultPoint" -ForegroundColor Yellow
    Write-Host "Datadir: $DataDir"
    $process = Start-Process -FilePath $NodePath -ArgumentList @("--appdir=$DataDir") -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
} finally {
    $env:KERYX_IBD_V2 = $old.Ibd
    $env:KERYX_IBD_V2_METRICS = $old.Metrics
    $env:KERYX_IBD_V2_FAULT_INJECTION = $old.Fault
    $env:KERYX_IBD_V2_FAULT_POINT = $old.Point
}
$process.WaitForExit()
Add-Content -Encoding ASCII (Join-Path $resultDir 'TEST-METADATA.txt') "exit_code=$($process.ExitCode)"
Add-Content -Encoding ASCII (Join-Path $resultDir 'TEST-METADATA.txt') "ended_utc=$([DateTime]::UtcNow.ToString('o'))"
$marker = "IBD v2 fault injection: aborting at $FaultPoint"
$found = (Select-String -LiteralPath $stdout,$stderr -SimpleMatch $marker -ErrorAction SilentlyContinue) -ne $null
if ($found) { Write-Host "Expected UTXO hard crash observed at $FaultPoint." -ForegroundColor Green }
else { Write-Warning "Process exited but the expected fault marker was not found. Inspect $resultDir." }
Write-Host "NEXT: .\RESUME-UTXO-CRASH-TEST.ps1 -DataDir '$DataDir'" -ForegroundColor Cyan
Write-Host "Evidence: $resultDir"
'@

Write-Lf 'scripts/ibd-v2/phase3/RESUME-UTXO-CRASH-TEST.ps1' @'
[CmdletBinding()]
param(
    [string]$NodePath = (Join-Path $PSScriptRoot 'keryxd.exe'),
    [string]$DataDir = 'E:\datanode\keryx-ibd-v2-utxo-realtest'
)
$ErrorActionPreference = 'Stop'
if (!(Test-Path -LiteralPath $NodePath -PathType Leaf)) { throw "Node not found: $NodePath" }
if (!(Test-Path -LiteralPath $DataDir -PathType Container)) { throw "Datadir not found: $DataDir" }
if (!(Get-ChildItem -LiteralPath $DataDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { throw 'The datadir is empty; nothing to resume.' }
if (Get-Process -Name keryxd -ErrorAction SilentlyContinue) { throw 'Another keryxd process is already running.' }
$env:KERYX_IBD_V2 = '1'
$env:KERYX_IBD_V2_METRICS = '1'
Remove-Item Env:KERYX_IBD_V2_FAULT_INJECTION -ErrorAction SilentlyContinue
Remove-Item Env:KERYX_IBD_V2_FAULT_POINT -ErrorAction SilentlyContinue
Write-Host 'Resuming SAME UTXO crash-test datadir with fault injection disabled.' -ForegroundColor Green
Write-Host 'Expected: RocksDB durable-prefix reconstruction, network prefix skip, then suffix-only DB writes.'
& $NodePath "--appdir=$DataDir"
exit $LASTEXITCODE
'@

# Include the now-touched UTXO store in the permanent local rustfmt gate.
Replace-Once '.github/workflows/ibd-v2-phase3-windows.yml' @'
            (Get-ChildItem 'consensus/src/model/stores' -Filter 'service_*.rs' -File | ForEach-Object FullName)
            (Resolve-Path 'keryxd/src/daemon.rs').Path
'@ @'
            (Get-ChildItem 'consensus/src/model/stores' -Filter 'service_*.rs' -File | ForEach-Object FullName)
            (Resolve-Path 'consensus/src/model/stores/utxo_set.rs').Path
            (Resolve-Path 'keryxd/src/daemon.rs').Path
'@

Write-Host 'Formatting UTXO recovery candidate...'
& rustfmt --edition 2024 --config skip_children=true `
    protocol/flows/src/ibd_v2/utxo_recovery.rs `
    protocol/flows/src/ibd_v2/mod.rs `
    protocol/flows/src/ibd_v2/service_state_recovery.rs `
    protocol/flows/src/ibd/flow.rs `
    consensus/src/model/stores/utxo_set.rs
if ($LASTEXITCODE -ne 0) { throw 'rustfmt failed' }

Write-Host 'Running focused UTXO recovery certification...'
& cargo check -p keryx-consensus --all-targets
if ($LASTEXITCODE -ne 0) { throw 'consensus check failed' }
& cargo check -p keryx-p2p-flows --all-targets
if ($LASTEXITCODE -ne 0) { throw 'flows check failed' }
& cargo check -p keryxd --all-targets
if ($LASTEXITCODE -ne 0) { throw 'keryxd check failed' }
& cargo clippy -p keryx-p2p-flows --all-targets --no-deps -- -D warnings -A clippy::collapsible_if
if ($LASTEXITCODE -ne 0) { throw 'clippy failed' }
& cargo test -p keryx-p2p-flows ibd_v2::utxo_recovery
if ($LASTEXITCODE -ne 0) { throw 'UTXO recovery tests failed' }
& cargo test -p keryx-p2p-flows ibd_v2::service_state_recovery
if ($LASTEXITCODE -ne 0) { throw 'Service State regression tests failed' }

Write-Host 'Committing certified UTXO recovery candidate...'
& git add protocol/flows/src/ibd_v2/utxo_recovery.rs protocol/flows/src/ibd_v2/mod.rs protocol/flows/src/ibd_v2/service_state_recovery.rs protocol/flows/src/ibd/flow.rs consensus/src/model/stores/utxo_set.rs scripts/ibd-v2/phase3/START-UTXO-CRASH-TEST.ps1 scripts/ibd-v2/phase3/RESUME-UTXO-CRASH-TEST.ps1 .github/workflows/ibd-v2-phase3-windows.yml
& git commit -m 'feat(ibd-v2): resume durable pruning UTXO imports'
if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
$sha = (& git rev-parse HEAD).Trim()
Write-Host "Certified candidate commit: $sha"
& git push origin HEAD:ibd-v2-phase3-persistent-state
if ($LASTEXITCODE -ne 0) { throw 'git push failed' }
