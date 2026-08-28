$ErrorActionPreference = 'Stop'

$base155 = 'bb408d54ca3992f7f9f4e269507f7603c234d24d'
$ibdPhase3 = '7be5d296527eceff8b3e550f9afa0bd63276e492'
$upstream156 = 'a8e23793363c509325881f6146176f39bf52f77f'
$targetBranch = 'ibd-v2-integrate-v1.5.6'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Replace-Required {
    param([string]$Text, [string]$Old, [string]$New, [string]$Label)
    if (-not $Text.Contains($Old)) { throw "required v1.5.6 merge anchor missing: $Label" }
    return $Text.Replace($Old, $New)
}

function Replace-AfterMarker {
    param([string]$Text, [string]$Marker, [string]$Old, [string]$New, [string]$Label)
    $markerIndex = $Text.IndexOf($Marker)
    if ($markerIndex -lt 0) { throw "required function marker missing: $Label" }
    $oldIndex = $Text.IndexOf($Old, $markerIndex)
    if ($oldIndex -lt 0) { throw "required v1.5.6 merge anchor missing after marker: $Label" }
    return $Text.Substring(0, $oldIndex) + $New + $Text.Substring($oldIndex + $Old.Length)
}

function Replace-RegionAfterMarker {
    param([string]$Text, [string]$Marker, [string]$Start, [string]$End, [string]$New, [string]$Label)
    $markerIndex = $Text.IndexOf($Marker)
    if ($markerIndex -lt 0) { throw "required function marker missing: $Label" }
    $startIndex = $Text.IndexOf($Start, $markerIndex)
    if ($startIndex -lt 0) { throw "required region start missing: $Label" }
    $endIndex = $Text.IndexOf($End, $startIndex)
    if ($endIndex -lt 0) { throw "required region end missing: $Label" }
    return $Text.Substring(0, $startIndex) + $New + $Text.Substring($endIndex)
}

function Merge-IbdFlowV156 {
    param([string]$Path)

    $text = [IO.File]::ReadAllText((Resolve-Path $Path)).Replace("`r`n", "`n")

    # v1.5.6 protocol-v11 compact PoM proof decoding.
    $text = Replace-Required $text "    pom::PomProof,`n" '' 'remove legacy PomProof import'
    $text = Replace-Required $text "    convert::{`n        header::{HeaderFormat, Versioned}," "    convert::{`n        block::decode_pom_proof,`n        header::{HeaderFormat, Versioned}," 'decode_pom_proof import'
    $text = Replace-Required $text "use std::{`n    sync::Arc," "use std::{`n    collections::HashMap,`n    sync::Arc," 'HashMap import'

    # v1.5.6 negotiation validates service-state checkpoint context against the relay header.
    $text = Replace-Required $text '        let negotiation_output = self.negotiate_missing_syncer_chain_segment(&session).await?;' '        let negotiation_output = self.negotiate_missing_syncer_chain_segment(&session, &relay_block.header).await?;' 'IBD negotiation relay header'

    # Preserve Phase 3 crash-safety arm, but follow v1.5.6 ordering: Service State must import
    # successfully before the pruning UTXO state is exposed as stable.
    $text = Replace-Required $text "        consensus.async_set_pruning_utxoset_stable().await;`n        self.sync_service_state(consensus, pruning_point, relay_header).await?;" "        self.sync_service_state(consensus, pruning_point, relay_header).await?;`n        consensus.async_set_pruning_utxoset_stable().await;" 'Service State before UTXO stable'

    # Insert the official chain-vote helper before our durable Service State implementation.
    if (-not $text.Contains('async fn service_commitment_votes(')) {
        $docMarker = '    /// Downloads the sealed service-bond state (every finality-flushed row up to the new pruning'
        $insertAt = $text.IndexOf($docMarker)
        if ($insertAt -lt 0) { throw 'could not locate Service State function for v1.5.6 vote helper' }
        $helper = @'
    /// The sealed service-state commitments carried by the last chain headers anchored at
    /// `pruning_point` (selected-parent chain below the headers-selected tip), with their counts;
    /// the relay header alone when no chain header carries that pruning point yet.
    async fn service_commitment_votes(
        &self,
        consensus: &ConsensusProxy,
        pruning_point: Hash,
        relay_header: &Header,
    ) -> Result<HashMap<Hash, usize>, ProtocolError> {
        const VOTE_DEPTH: usize = 512;
        let mut votes: HashMap<Hash, usize> = HashMap::new();
        let mut hash = consensus.async_get_headers_selected_tip().await;
        for _ in 0..VOTE_DEPTH {
            let header = consensus.async_get_header(hash).await?;
            if header.pruning_point == pruning_point {
                *votes.entry(header.service_state_hash).or_default() += 1;
            }
            let Ok(ghostdag) = consensus.async_get_ghostdag_data(hash).await else { break };
            hash = ghostdag.selected_parent;
        }
        if votes.is_empty() && relay_header.pruning_point == pruning_point {
            votes.insert(relay_header.service_state_hash, 1);
        }
        if votes.is_empty() {
            return Err(ProtocolError::Other("no validated header anchors the negotiated pruning point"));
        }
        Ok(votes)
    }

'@
        $text = $text.Substring(0, $insertAt) + $helper.Replace("`r`n", "`n") + $text.Substring($insertAt)
    }
    $text = $text.Replace(
        '    /// point) and verifies its MuHash against `service_state_hash` of the already-validated relay' + "`n" + '    /// header before importing. No-op below the H6 gate.',
        '    /// point) and verifies its MuHash against the commitment the chain''s headers carry for it' + "`n" + '    /// before importing. No-op below the H6 gate.'
    )

    # Replace the old single-header expectation with the official v1.5.6 majority/checkpoint model.
    $expectedStart = '        // The expected commitment lives in headers whose own pruning point is the one we synced:'
    $expectedEnd = '        let mut recovery = if crate::ibd_v2::enabled_from_env() {'
    $startIndex = $text.IndexOf($expectedStart)
    if ($startIndex -lt 0) { throw 'could not locate legacy Service State expected-commitment block' }
    $endIndex = $text.IndexOf($expectedEnd, $startIndex)
    if ($endIndex -lt 0) { throw 'could not locate Service State recovery block after expected commitment' }
    $expectedReplacement = @'
        let votes = self.service_commitment_votes(consensus, pruning_point, relay_header).await?;
        let majority = votes.iter().max_by_key(|(commitment, count)| (**count, **commitment)).map(|(c, _)| *c).unwrap();
        let checkpoint = self.ctx.config.service_state_checkpoint.filter(|(daa, _)| *daa <= pp_daa);

'@
    $text = $text.Substring(0, $startIndex) + $expectedReplacement.Replace("`r`n", "`n") + $text.Substring($endIndex)

    # Our recovery path recomputes the full durable spool at the end. Extend that authoritative
    # recomputation with the v1.5.6 checkpoint-prefix verification rather than trusting stream state.
    $text = Replace-Required $text "        let mut prefix_rows = 0usize;`n        for row in &rows {" "        let mut prefix_rows = 0usize;`n        let mut checkpoint_rows = 0usize;`n        let mut checkpoint_acc = MuHash::new();`n        for row in &rows {" 'checkpoint accumulator declarations'
    $text = Replace-Required $text "            if daa <= pp_daa {`n                acc.add_element(row);`n                prefix_rows += 1;`n            }" "            if daa <= pp_daa {`n                acc.add_element(row);`n                prefix_rows += 1;`n                if checkpoint.is_some_and(|(cp_daa, _)| daa <= cp_daa) {`n                    checkpoint_acc.add_element(row);`n                    checkpoint_rows += 1;`n                }`n            }" 'checkpoint prefix accumulation'

    $legacyExpectedCheck = @'
        if computed != expected {
            return Err(ProtocolError::OtherOwned(format!(
                "service-state verification failed: peer rows hash to {}, header commits {}",
                computed, expected
            )));
        }
'@
    $acceptedCheck = @'
        // With a checkpoint, the rows up to it must reproduce it and the whole set must match a
        // commitment the chain carries (any voted value, or the checkpoint itself when the
        // pruning point sits exactly on it); without one, the majority commitment decides.
        let accepted = match checkpoint {
            Some((cp_daa, cp_hash)) => {
                let at_checkpoint = if checkpoint_rows == 0 { Hash::default() } else { checkpoint_acc.finalize() };
                if at_checkpoint != cp_hash {
                    return Err(ProtocolError::OtherOwned(format!(
                        "service-state verification failed: peer rows up to daa {} hash to {}, checkpoint is {}",
                        cp_daa, at_checkpoint, cp_hash
                    )));
                }
                pp_daa == cp_daa || votes.contains_key(&computed)
            }
            None => computed == majority,
        };
        if !accepted {
            return Err(ProtocolError::OtherOwned(format!(
                "service-state verification failed: peer rows hash to {}, header commits {}",
                computed, majority
            )));
        }
'@
    $text = Replace-Required $text $legacyExpectedCheck.Replace("`r`n", "`n") $acceptedCheck.Replace("`r`n", "`n") 'v1.5.6 Service State acceptance logic'

    # Pruning-anticone body-only path: request no old proofs and decode either v10 legacy or v11 compact proof.
    $noHeadersMarker = '    async fn sync_missing_trusted_bodies_no_headers('
    $oldBodiesRequest = '                    RequestBlockBodiesMessage { hashes: chunk.iter().map(|h| h.into()).collect() }'
    $noProofBodiesRequest = @'
                    RequestBlockBodiesMessage {
                        hashes: chunk.iter().map(|h| h.into()).collect(),
                        // This path discards proofs unconditionally (below), so ask for none.
                        pom_proof_min_daa: Some(u64::MAX),
                    }
'@
    $text = Replace-AfterMarker $text $noHeadersMarker $oldBodiesRequest $noProofBodiesRequest.TrimEnd().Replace("`r`n", "`n") 'trusted body-only request horizon'

    $noHeadersStart = '                let pom_tier = msg.pom_tier.map(|tier| tier as u8);'
    $noHeadersEnd = '                if blk_body.is_empty() {'
    $noHeadersDecode = @'
                // Header first: compact v11 proofs derive their seed/tree shape from it.
                // TODO (relaxed): make header queries in a batch.
                let blk_header = consensus.async_get_header(hash).await.map_err(|err| {
                    ProtocolError::OtherOwned(format!("syncee inconsistency: missing block header for {}, err: {}", hash, err))
                })?;
                let pom_tier = msg.pom_tier.map(|tier| tier as u8);
                let pom_proof = decode_pom_proof(&blk_header, msg.pom_proof.clone(), msg.pom_proof_deduped.clone())
                    .map_err(|_| ProtocolError::OtherOwned(format!("invalid pom_proof for trusted block {}", hash)))?
                    .map(Arc::new);
                let blk_body: BlockBody = msg.try_into()?;
'@
    $text = Replace-RegionAfterMarker $text $noHeadersMarker $noHeadersStart $noHeadersEnd $noHeadersDecode.Replace("`r`n", "`n") 'trusted compact proof decode'

    # Pruning-anticone full-block path also asks the v11 server to omit proofs we always discard.
    $fullTrustedMarker = '    async fn sync_missing_trusted_bodies_full_blocks('
    $oldIbdRequest = '                    RequestIbdBlocksMessage { hashes: chunk.iter().map(|h| h.into()).collect() }'
    $noProofIbdRequest = @'
                    RequestIbdBlocksMessage {
                        hashes: chunk.iter().map(|h| h.into()).collect(),
                        // This path discards proofs unconditionally (below), so ask for none.
                        pom_proof_min_daa: Some(u64::MAX),
                    }
'@
    $text = Replace-AfterMarker $text $fullTrustedMarker $oldIbdRequest $noProofIbdRequest.TrimEnd().Replace("`r`n", "`n") 'trusted full-block request horizon'

    # Normal full-block IBD declares the local proof-retention horizon to the server.
    $queueFullMarker = '    async fn queue_block_processing_chunk_full_block('
    $proofHorizonIbdRequest = @'
                RequestIbdBlocksMessage {
                    hashes: chunk.iter().map(|h| h.into()).collect(),
                    // State our local proof retention policy at the source.
                    pom_proof_min_daa: Some(high_daa.saturating_sub(POM_PROOF_SERVE_DEPTH_DAA)),
                }
'@
    $text = Replace-AfterMarker $text $queueFullMarker '                RequestIbdBlocksMessage { hashes: chunk.iter().map(|h| h.into()).collect() }' $proofHorizonIbdRequest.TrimEnd().Replace("`r`n", "`n") 'full-block proof horizon'

    # Normal body-only IBD: request our horizon, count either encoding in metrics, and decode v11.
    $queueBodyMarker = '    async fn queue_block_processing_chunk_body_only('
    $proofHorizonBodyRequest = @'
                RequestBlockBodiesMessage {
                    hashes: chunk.iter().map(|h| h.into()).collect(),
                    // State our local proof retention policy at the source.
                    pom_proof_min_daa: Some(high_daa.saturating_sub(POM_PROOF_SERVE_DEPTH_DAA)),
                }
'@
    $text = Replace-AfterMarker $text $queueBodyMarker '                RequestBlockBodiesMessage { hashes: chunk.iter().map(|h| h.into()).collect() }' $proofHorizonBodyRequest.TrimEnd().Replace("`r`n", "`n") 'body-only proof horizon'

    $oldProofBytes = @'
            let proof_bytes =
                if metrics_enabled() { msg.pom_proof.as_deref().map(|proof| proof.len() as u64).unwrap_or(0) } else { 0 };
'@
    $newProofBytes = @'
            let proof_bytes = if metrics_enabled() {
                msg.pom_proof
                    .as_ref()
                    .or(msg.pom_proof_deduped.as_ref())
                    .map(|proof| proof.len() as u64)
                    .unwrap_or(0)
            } else {
                0
            };
'@
    $text = Replace-AfterMarker $text $queueBodyMarker $oldProofBytes.Replace("`r`n", "`n") $newProofBytes.Replace("`r`n", "`n") 'compact proof byte metrics'

    $queueBodyStart = '            let pom_tier = msg.pom_tier.map(|t| t as u8);'
    $queueBodyEnd = '            let blk_body: BlockBody = msg.try_into()?;'
    $queueBodyDecode = @'
            let pom_tier = msg.pom_tier.map(|t| t as u8);
            let decode_started = metrics_enabled().then(Instant::now);
            // Header first: compact v11 proofs derive their seed/tree shape from it.
            // TODO (relaxed): make header queries in a batch.
            let blk_header = consensus.async_get_header(expected_hash).await.map_err(|err| {
                ProtocolError::OtherOwned(format!("syncee inconsistency: missing block header for {}, err: {}", expected_hash, err))
            })?;
            let pom_proof = decode_pom_proof(&blk_header, msg.pom_proof.clone(), msg.pom_proof_deduped.clone())
                .map_err(|_| ProtocolError::OtherOwned(format!("invalid pom_proof for block {}", expected_hash)))?
                .map(Arc::new);
            if let Some(decode_started) = decode_started {
                pom.decode_time = pom.decode_time.saturating_add(decode_started.elapsed());
            }
'@
    $text = Replace-RegionAfterMarker $text $queueBodyMarker $queueBodyStart $queueBodyEnd $queueBodyDecode.Replace("`r`n", "`n") 'normal compact proof decode'

    [IO.File]::WriteAllText((Resolve-Path $Path), $text, $utf8NoBom)
}

Write-Host "IBD v2 source: $ibdPhase3"
Write-Host "Official v1.5.6: $upstream156"

git fetch origin ibd-v2-base-v1.5.6 $targetBranch --no-tags
if ($LASTEXITCODE -ne 0) { throw 'git fetch failed' }

git config user.name 'Keryx IBD V2 Local Runner'
git config user.email 'actions@localhost'

git merge --no-commit --no-ff origin/ibd-v2-base-v1.5.6
$mergeExit = $LASTEXITCODE

if ($mergeExit -ne 0) {
    $conflicts = @(git diff --name-only --diff-filter=U)
    Write-Host "Initial merge conflicts ($($conflicts.Count)):"
    $conflicts | ForEach-Object { Write-Host " - $_" }

    foreach ($path in $conflicts) {
        Write-Host "Resolving v1.5.6 overlap: $path"
        git checkout --ours -- $path
        if ($LASTEXITCODE -ne 0) { throw "failed to select certified IBD side for $path" }

        if ($path -eq 'consensus/src/pipeline/virtual_processor/tests.rs') {
            $current = [IO.File]::ReadAllText((Resolve-Path $path)).Replace("`r`n", "`n")
            $marker = '#[tokio::test]' + "`n" + 'async fn reward_mint_window_is_the_same_off_the_committed_chain()'
            if (-not $current.Contains('reward_mint_window_is_the_same_off_the_committed_chain')) {
                $upstreamLines = @(git show "${upstream156}:$path")
                if ($LASTEXITCODE -ne 0) { throw 'failed to read upstream v1.5.6 tests.rs' }
                $upstreamText = [string]::Join("`n", $upstreamLines) + "`n"
                $start = $upstreamText.IndexOf($marker)
                if ($start -lt 0) { throw 'could not locate v1.5.6 reward-routing regression test' }
                $addition = $upstreamText.Substring($start)
                if (-not $current.EndsWith("`n")) { $current += "`n" }
                $current += "`n" + $addition
                [IO.File]::WriteAllText((Resolve-Path $path), $current, $utf8NoBom)
            }
            git add -- $path
            continue
        }

        if ($path -eq 'protocol/flows/src/ibd/flow.rs') {
            Merge-IbdFlowV156 $path
            git add -- $path
            continue
        }

        throw "unexpected v1.5.6 merge conflict: $path"
    }
}

$remaining = @(git diff --name-only --diff-filter=U)
if ($remaining.Count -gt 0) { throw "v1.5.6 integration still has unresolved files: $($remaining -join ', ')" }

$pom = Get-Content -Raw 'consensus/core/src/pom_v4.rs'
if ($pom -notmatch '#\[target_feature\(enable = "neon"\)\]\s*unsafe fn half') {
    throw 'IBD v2 AArch64/NEON compatibility hook was lost during v1.5.6 integration'
}
$ctx = Get-Content -Raw 'protocol/flows/src/flow_context.rs'
if ($ctx -notmatch 'ibd_v2_state_dir') {
    throw 'IBD v2 durable state directory hook was lost during v1.5.6 integration'
}
$proto = Get-Content -Raw 'protocol/p2p/proto/p2p.proto'
if ($proto -notmatch 'previousRowFingerprint' -or $proto -notmatch 'startCursor') {
    throw 'IBD v2 resumable Service State wire fields were lost during v1.5.6 integration'
}
if ($proto -notmatch 'pom_proof_deduped' -or $proto -notmatch 'pom_proof_min_daa') {
    throw 'official v1.5.6 compact PoM wire fields were lost during integration'
}
$flow = Get-Content -Raw 'protocol/flows/src/ibd/flow.rs'
foreach ($required in @('ServiceStateRecovery','UtxoRecovery','IbdStageTracker','service_commitment_votes','service_state_checkpoint','decode_pom_proof','pom_proof_min_daa')) {
    if ($flow -notmatch [regex]::Escape($required)) { throw "required integrated IBD symbol missing: $required" }
}
$serviceSyncIndex = $flow.IndexOf('self.sync_service_state(consensus, pruning_point, relay_header).await?;')
$stableIndex = $flow.IndexOf('consensus.async_set_pruning_utxoset_stable().await;')
if ($serviceSyncIndex -lt 0 -or $stableIndex -lt 0 -or $serviceSyncIndex -gt $stableIndex) {
    throw 'v1.5.6 Service State must complete before UTXO stability is exposed'
}
$tests = Get-Content -Raw 'consensus/src/pipeline/virtual_processor/tests.rs'
if ($tests -notmatch 'pruning_point_utxo_import_replay_is_idempotent' -or $tests -notmatch 'reward_mint_window_is_the_same_off_the_committed_chain') {
    throw 'required Phase 3/v1.5.6 virtual processor regression tests are missing'
}

$roadmapPath = 'docs/ibd-v2/ROADMAP.md'
if (Test-Path $roadmapPath) {
    $roadmap = Get-Content -Raw $roadmapPath
    $roadmap = $roadmap.Replace(
        'Active frozen comparison base: Keryx v1.5.5, commit `bb408d54ca3992f7f9f4e269507f7603c234d24d`.',
        'Active upstream development base: Keryx v1.5.6, commit `a8e23793363c509325881f6146176f39bf52f77f`. Canonical performance comparison remains RUN A v1.5.5 until a new baseline is explicitly frozen.'
    )
    [IO.File]::WriteAllText((Resolve-Path $roadmapPath), $roadmap, $utf8NoBom)
}

git add -A
if ($LASTEXITCODE -ne 0) { throw 'git add failed' }
$unmerged = @(git diff --cached --name-only --diff-filter=U)
if ($unmerged.Count -gt 0) { throw "unmerged files remain: $($unmerged -join ', ')" }

Write-Host 'Formatting merged IBD v1.5.6 files...'
rustfmt --edition 2024 --config skip_children=true protocol/flows/src/ibd/flow.rs consensus/src/pipeline/virtual_processor/tests.rs
if ($LASTEXITCODE -ne 0) { throw 'rustfmt failed on merged v1.5.6 files' }
git add protocol/flows/src/ibd/flow.rs consensus/src/pipeline/virtual_processor/tests.rs

Write-Host 'Running v1.5.6 integration checks...'
cargo check -p keryx-consensus-core --all-targets
if ($LASTEXITCODE -ne 0) { throw 'consensus-core check failed' }
cargo check -p keryx-consensus --all-targets
if ($LASTEXITCODE -ne 0) { throw 'consensus check failed' }
cargo check -p keryx-p2p-lib --all-targets
if ($LASTEXITCODE -ne 0) { throw 'p2p wire check failed' }
cargo check -p keryx-p2p-flows --all-targets
if ($LASTEXITCODE -ne 0) { throw 'p2p flows check failed' }
cargo check -p keryxd --all-targets
if ($LASTEXITCODE -ne 0) { throw 'keryxd check failed' }

cargo test -p keryx-p2p-flows ibd_v2
if ($LASTEXITCODE -ne 0) { throw 'IBD v2 recovery tests failed' }
cargo test -p keryx-consensus pruning_point_utxo_import_replay_is_idempotent
if ($LASTEXITCODE -ne 0) { throw 'UTXO replay regression test failed' }
cargo test -p keryx-consensus reward_mint_window_is_the_same_off_the_committed_chain
if ($LASTEXITCODE -ne 0) { throw 'v1.5.6 reward-routing regression test failed' }

cargo build --release -p keryxd
if ($LASTEXITCODE -ne 0) { throw 'release build failed' }

git commit -m 'chore(ibd-v2): integrate official Keryx v1.5.6'
if ($LASTEXITCODE -ne 0) { throw 'merge commit failed' }
$sha = (git rev-parse HEAD).Trim()
Write-Host "Integrated v1.5.6 HEAD: $sha"
git push origin HEAD:$targetBranch
if ($LASTEXITCODE -ne 0) { throw 'push failed' }

$exe = Join-Path $PWD 'target\release\keryxd.exe'
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash.ToLowerInvariant()
Write-Host "keryxd.exe SHA256=$hash"
