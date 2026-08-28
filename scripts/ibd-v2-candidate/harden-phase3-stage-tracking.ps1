$ErrorActionPreference = 'Stop'
$path = 'scripts/ibd-v2/phase3/apply-stage-tracking.ps1'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$text = ([System.IO.File]::ReadAllText($path)).Replace("`r`n", "`n")

$oldHeadersProof = @'
                    Ok(()) => {
                        if let Some(tracker) = &stage_tracker {
                            tracker
                                .mark_verified(Stage::Pruning, 1, Some(1))
                                .and_then(|_| tracker.mark_verified(Stage::Headers, 1, Some(1)))
                                .map_err(|err| ProtocolError::OtherOwned(format!("failed to verify IBD v2 headers-proof stages: {err}")))?;
                        }
                        spawn_blocking(|| staging.commit()).await.unwrap();
                        if let Some(tracker) = &stage_tracker {
                            tracker
                                .mark_committed(Stage::Pruning, 1, Some(1))
                                .and_then(|_| tracker.mark_committed(Stage::Headers, 1, Some(1)))
                                .map_err(|err| ProtocolError::OtherOwned(format!("failed to commit IBD v2 headers-proof stages: {err}")))?;
                        }
                        info!(
'@
$newHeadersProof = @'
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
if (-not $text.Contains($oldHeadersProof)) { throw 'headers-proof durability hotfix anchor not found' }
$text = $text.Replace($oldHeadersProof, $newHeadersProof)

$oldPom = @'
        if let Some(tracker) = &body_stage_tracker {
            tracker
                .mark_verified(Stage::Pom, 1, Some(1))
                .and_then(|_| tracker.mark_verified(Stage::Bodies, 1, Some(1)))
                .and_then(|_| tracker.mark_committed(Stage::Pom, 1, Some(1)))
                .and_then(|_| tracker.mark_committed(Stage::Bodies, 1, Some(1)))
                .map_err(|err| ProtocolError::OtherOwned(format!("failed to commit IBD v2 Bodies/PoM stages: {err}")))?;
        }
'@
$newPom = @'
        if let Some(tracker) = &body_stage_tracker {
            // Phase 3 can prove that the PoM work for this body-sync cycle was
            // validated, but Phase 5 owns independent proof persistence and the
            // eventual PoM COMMITTED transition.
            tracker
                .mark_verified(Stage::Pom, 1, Some(1))
                .and_then(|_| tracker.mark_verified(Stage::Bodies, 1, Some(1)))
                .and_then(|_| tracker.mark_committed(Stage::Bodies, 1, Some(1)))
                .map_err(|err| ProtocolError::OtherOwned(format!("failed to finalize IBD v2 Bodies/PoM tracking: {err}")))?;
        }
'@
if (-not $text.Contains($oldPom)) { throw 'PoM Phase 5 boundary hotfix anchor not found' }
$text = $text.Replace($oldPom, $newPom)

[System.IO.File]::WriteAllText($path, $text, $utf8NoBom)
Write-Host 'Applied canonical roadmap durability boundaries to the Phase 3 candidate script.'
