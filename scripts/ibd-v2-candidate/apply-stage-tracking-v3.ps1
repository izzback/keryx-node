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
    $index = $Text.IndexOf($Old, [System.StringComparison]::Ordinal)
    if ($index -lt 0) { throw "Required canonical Phase 3 anchor not found: $Label" }
    return $Text.Substring(0, $index) + $New + $Text.Substring($index + $Old.Length)
}

Copy-Item -LiteralPath 'scripts/ibd-v2-candidate/stage-tracking-source.rs' -Destination 'protocol/flows/src/ibd_v2/stage_tracking.rs' -Force

$mod = Read-Lf 'protocol/flows/src/ibd_v2/mod.rs'
$mod = Replace-Required $mod ('pub mod service_state_spool;' + "`n" + 'pub mod state;') ('pub mod service_state_spool;' + "`n" + 'pub mod stage_tracking;' + "`n" + 'pub mod state;') 'mod export'
Write-Lf 'protocol/flows/src/ibd_v2/mod.rs' $mod

$flow = Read-Lf 'protocol/flows/src/ibd/flow.rs'

$old = '        service_state_recovery::ServiceStateRecovery,' + "`n" + '        utxo_recovery::UtxoRecovery,'
$new = '        service_state_recovery::ServiceStateRecovery,' + "`n" + '        stage_tracking::IbdStageTracker,' + "`n" + '        state::Stage,' + "`n" + '        utxo_recovery::UtxoRecovery,'
$flow = Replace-Required $flow $old $new 'flow imports'

$anchor = '    async fn start_impl(&mut self) -> Result<(), ProtocolError> {'
$helper = @'
    fn stage_tracker(&self, pruning_point: Hash) -> Result<Option<IbdStageTracker>, ProtocolError> {
        if !crate::ibd_v2::enabled_from_env() {
            return Ok(None);
        }
        IbdStageTracker::open(self.ctx.ibd_v2_state_dir(), self.ctx.config.genesis.hash, pruning_point)
            .map(Some)
            .map_err(|err| ProtocolError::OtherOwned(format!("failed to open IBD v2 independent stage tracker: {err}")))
    }

'@
$flow = Replace-Required $flow $anchor ($helper + $anchor) 'stage tracker helper'

$old = '                let pruning_point = session.async_pruning_point().await;' + "`n`n" + '                info!("syncing ahead from current pruning point");'
$new = @'
                let pruning_point = session.async_pruning_point().await;
                let stage_tracker = self.stage_tracker(pruning_point)?;
                if let Some(tracker) = &stage_tracker {
                    tracker
                        .reconcile_committed_from_consensus(Stage::Pruning, 1, Some(1))
                        .map_err(|err| ProtocolError::OtherOwned(format!("failed to reconcile IBD v2 Pruning stage: {err}")))?;
                }

                info!("syncing ahead from current pruning point");
'@
$flow = Replace-Required $flow $old $new 'normal Sync pruning tracking'

$comment = '                // Once utxo is valid, simply sync missing headers'
$beforeHeaders = @'
                if let Some(tracker) = &stage_tracker {
                    tracker
                        .begin_cycle(Stage::Headers)
                        .map_err(|err| ProtocolError::OtherOwned(format!("failed to begin IBD v2 Headers stage: {err}")))?;
                }
'@
$flow = Replace-Required $flow $comment ($comment + "`n" + $beforeHeaders.TrimEnd("`r", "`n")) 'begin normal Headers stage'

$old = '                    .await?;' + "`n" + '            }' + "`n" + '            IbdType::DownloadHeadersProof => {'
$new = @'
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
$flow = Replace-Required $flow $old $new 'finish normal Headers stage'

$old = '            IbdType::DownloadHeadersProof => {' + "`n" + '                drop(session); // Avoid holding the previous consensus throughout the staging IBD'
$new = @'
            IbdType::DownloadHeadersProof => {
                let stage_tracker = self.stage_tracker(negotiation_output.syncer_pruning_point)?;
                if let Some(tracker) = &stage_tracker {
                    tracker
                        .begin_cycle(Stage::Pruning)
                        .and_then(|_| tracker.begin_cycle(Stage::Headers))
                        .map_err(|err| ProtocolError::OtherOwned(format!("failed to begin IBD v2 headers-proof stages: {err}")))?;
                }
                drop(session); // Avoid holding the previous consensus throughout the staging IBD
'@
$flow = Replace-Required $flow $old $new 'headers-proof begin'

$old = '                        spawn_blocking(|| staging.commit()).await.unwrap();'
$new = @'
                        spawn_blocking(|| staging.commit()).await.unwrap();
                        if let Some(tracker) = &stage_tracker {
                            tracker
                                .reconcile_committed_from_consensus(Stage::Pruning, 1, Some(1))
                                .and_then(|_| tracker.reconcile_committed_from_consensus(Stage::Headers, 1, Some(1)))
                                .map_err(|err| ProtocolError::OtherOwned(format!("failed to reconcile committed IBD v2 headers-proof stages: {err}")))?;
                        }
'@
$flow = Replace-Required $flow $old $new 'headers-proof durable commit'

$old = '            IbdType::PruningCatchUp { highest_known_syncer_chain_hash } => {' + "`n" + '                info!("catching up to new pruning point {} ", negotiation_output.syncer_pruning_point);'
$new = @'
            IbdType::PruningCatchUp { highest_known_syncer_chain_hash } => {
                let stage_tracker = self.stage_tracker(negotiation_output.syncer_pruning_point)?;
                if let Some(tracker) = &stage_tracker {
                    tracker
                        .begin_cycle(Stage::Pruning)
                        .and_then(|_| tracker.begin_cycle(Stage::Headers))
                        .map_err(|err| ProtocolError::OtherOwned(format!("failed to begin IBD v2 pruning-catchup stages: {err}")))?;
                }
                info!("catching up to new pruning point {} ", negotiation_output.syncer_pruning_point);
'@
$flow = Replace-Required $flow $old $new 'pruning catchup begin'

$old = '                    Ok(()) => {' + "`n" + '                        info!("header stage of pruning catchup from peer {} completed", self.router);'
$new = @'
                    Ok(()) => {
                        if let Some(tracker) = &stage_tracker {
                            tracker
                                .reconcile_committed_from_consensus(Stage::Pruning, 1, Some(1))
                                .and_then(|_| tracker.reconcile_committed_from_consensus(Stage::Headers, 1, Some(1)))
                                .map_err(|err| ProtocolError::OtherOwned(format!("failed to reconcile committed IBD v2 pruning-catchup stages: {err}")))?;
                        }
                        info!("header stage of pruning catchup from peer {} completed", self.router);
'@
$flow = Replace-Required $flow $old $new 'pruning catchup committed'

$comment = '        // Sync missing bodies in the past of the (possibly ceiling-capped) sync target'
$bodyBegin = @'
        // Canonical Phase 3 tracking keeps Bodies and PoM independent even while
        // v1.5.5 still transports them through the same body pipeline. Phase 5
        // owns independent PoM persistence/provider semantics.
        let active_pruning_point = session.async_pruning_point().await;
        let body_stage_tracker = self.stage_tracker(active_pruning_point)?;
        if let Some(tracker) = &body_stage_tracker {
            tracker
                .set_body_sync_target(body_target)
                .and_then(|_| tracker.begin_cycle(Stage::Bodies))
                .and_then(|_| tracker.begin_cycle(Stage::Pom))
                .map_err(|err| ProtocolError::OtherOwned(format!("failed to begin IBD v2 Bodies/PoM stages: {err}")))?;
        }

'@
$flow = Replace-Required $flow $comment ($bodyBegin + $comment) 'begin Bodies and PoM stages'

$old = '        if self.sync_ceiling().is_none() {' + "`n" + '            self.sync_missing_block_bodies(&session, relay_block.hash()).await?;' + "`n" + '        }'
$new = @'
        if self.sync_ceiling().is_none() {
            if let Some(tracker) = &body_stage_tracker {
                tracker
                    .set_body_sync_target(relay_block.hash())
                    .map_err(|err| ProtocolError::OtherOwned(format!("failed to advance IBD v2 body-sync target: {err}")))?;
            }
            self.sync_missing_block_bodies(&session, relay_block.hash()).await?;
        }
'@
$flow = Replace-Required $flow $old $new 'relay body target tracking'

$comment = '        // Following IBD we revalidate orphans since many of them might have been processed during the IBD'
$bodyFinish = @'
        if let Some(tracker) = &body_stage_tracker {
            // Phase 3 proves PoM work for this cycle was validated. Phase 5 owns
            // independent proof persistence and the eventual PoM COMMITTED state.
            tracker
                .mark_verified(Stage::Pom, 1, Some(1))
                .and_then(|_| tracker.mark_verified(Stage::Bodies, 1, Some(1)))
                .and_then(|_| tracker.mark_committed(Stage::Bodies, 1, Some(1)))
                .map_err(|err| ProtocolError::OtherOwned(format!("failed to finalize IBD v2 Bodies/PoM tracking: {err}")))?;
        }

'@
$flow = Replace-Required $flow $comment ($bodyFinish + $comment) 'finish Bodies and PoM stages'

Write-Lf 'protocol/flows/src/ibd/flow.rs' $flow

& rustfmt --edition 2024 --config skip_children=true protocol/flows/src/ibd_v2/stage_tracking.rs protocol/flows/src/ibd_v2/mod.rs protocol/flows/src/ibd/flow.rs
if ($LASTEXITCODE -ne 0) { throw "rustfmt failed with exit code $LASTEXITCODE" }

cargo check -p keryx-p2p-flows --all-targets
if ($LASTEXITCODE -ne 0) { throw "p2p-flows check failed with exit code $LASTEXITCODE" }
cargo check -p keryxd --all-targets
if ($LASTEXITCODE -ne 0) { throw "keryxd check failed with exit code $LASTEXITCODE" }
cargo clippy -p keryx-p2p-flows --all-targets --no-deps -- -D warnings -A clippy::collapsible_if
if ($LASTEXITCODE -ne 0) { throw "clippy failed with exit code $LASTEXITCODE" }
cargo test -p keryx-p2p-flows stage_tracking
if ($LASTEXITCODE -ne 0) { throw "stage tracking tests failed with exit code $LASTEXITCODE" }
cargo test -p keryx-p2p-flows service_state_recovery
if ($LASTEXITCODE -ne 0) { throw "Service State regression tests failed with exit code $LASTEXITCODE" }
cargo test -p keryx-p2p-flows utxo_recovery
if ($LASTEXITCODE -ne 0) { throw "UTXO regression tests failed with exit code $LASTEXITCODE" }

git config user.name 'Keryx IBD V2 Local Runner'
git config user.email 'actions@localhost'
git add -- protocol/flows/src/ibd/flow.rs protocol/flows/src/ibd_v2/mod.rs protocol/flows/src/ibd_v2/stage_tracking.rs
if ($LASTEXITCODE -ne 0) { throw 'git add failed' }
$staged = @(git diff --cached --name-only)
$expected = @('protocol/flows/src/ibd/flow.rs', 'protocol/flows/src/ibd_v2/mod.rs', 'protocol/flows/src/ibd_v2/stage_tracking.rs')
if ($staged.Count -ne $expected.Count) { throw "Unexpected staged file count: $($staged.Count)" }
foreach ($path in $expected) { if ($staged -notcontains $path) { throw "Expected staged file missing: $path" } }

git commit -m 'feat(ibd-v2): track all Phase 3 stages independently'
if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
git push origin HEAD:ibd-v2-phase3-persistent-state
if ($LASTEXITCODE -ne 0) { throw 'git push failed' }
Write-Host 'Canonical Phase 3 independent stage tracking certified and pushed.'
