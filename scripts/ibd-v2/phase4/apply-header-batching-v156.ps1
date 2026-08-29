$ErrorActionPreference = 'Stop'

$branch = 'ibd-v2-phase4-db-batching'
$phase41 = 'c1e69e56154fe7f762856aaa8f7e5dce6261d673'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-Text([string]$Path) {
    [IO.File]::ReadAllText((Resolve-Path $Path))
}

function Write-Text([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText((Resolve-Path $Path), $Text, $utf8NoBom)
}

function Replace-Once([string]$Path, [string]$Old, [string]$New, [string]$Label) {
    $text = Read-Text $Path
    $first = $text.IndexOf($Old, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "$Label: source marker not found in $Path" }
    $second = $text.IndexOf($Old, $first + $Old.Length, [StringComparison]::Ordinal)
    if ($second -ge 0) { throw "$Label: source marker occurs more than once in $Path" }
    $text = $text.Substring(0, $first) + $New + $text.Substring($first + $Old.Length)
    Write-Text $Path $text
}

$head = (git rev-parse HEAD).Trim()
git merge-base --is-ancestor $phase41 $head
if ($LASTEXITCODE -ne 0) { throw "Phase 4.1 functional commit $phase41 is not an ancestor of HEAD $head" }
$dirty = @(git status --porcelain --untracked-files=no)
if ($dirty.Count -ne 0) { throw "tracked source tree is dirty before Phase 4.2 patch: $($dirty -join '; ')" }

# 1) Consensus API: ordered batch lookup. The Vec is intentionally owned so the async proxy can
# move the whole request into one spawn_blocking closure.
$apiPath = 'consensus/core/src/api/mod.rs'
$apiOld = @'
    fn get_header(&self, hash: Hash) -> ConsensusResult<Arc<Header>> {
        unimplemented!()
    }

    fn get_headers_selected_tip(&self) -> Hash {
'@
$apiNew = @'
    fn get_header(&self, hash: Hash) -> ConsensusResult<Arc<Header>> {
        unimplemented!()
    }

    /// Returns headers in exactly the same order as `hashes`. The first missing header aborts the
    /// batch with the same `HeaderNotFound` error as `get_header`.
    fn get_headers(&self, hashes: Vec<Hash>) -> ConsensusResult<Vec<Arc<Header>>> {
        unimplemented!()
    }

    fn get_headers_selected_tip(&self) -> Hash {
'@
Replace-Once $apiPath $apiOld $apiNew 'ConsensusApi get_headers insertion'

# 2) Concrete consensus implementation. This deliberately keeps the existing header-store lookup
# semantics but executes the entire chunk inside one blocking consensus call instead of one Tokio
# spawn_blocking per block.
$consensusPath = 'consensus/src/consensus/mod.rs'
$consensusOld = @'
    fn get_header(&self, hash: Hash) -> ConsensusResult<Arc<Header>> {
        self.headers_store.get_header(hash).optional().unwrap().ok_or(ConsensusError::HeaderNotFound(hash))
    }

    fn get_headers_selected_tip(&self) -> Hash {
'@
$consensusNew = @'
    fn get_header(&self, hash: Hash) -> ConsensusResult<Arc<Header>> {
        self.headers_store.get_header(hash).optional().unwrap().ok_or(ConsensusError::HeaderNotFound(hash))
    }

    fn get_headers(&self, hashes: Vec<Hash>) -> ConsensusResult<Vec<Arc<Header>>> {
        hashes
            .into_iter()
            .map(|hash| self.headers_store.get_header(hash).optional().unwrap().ok_or(ConsensusError::HeaderNotFound(hash)))
            .collect()
    }

    fn get_headers_selected_tip(&self) -> Hash {
'@
Replace-Once $consensusPath $consensusOld $consensusNew 'Consensus get_headers implementation'

# 3) Async proxy: exactly one spawn_blocking for the whole ordered chunk.
$sessionPath = 'components/consensusmanager/src/session.rs'
$sessionOld = @'
    pub async fn async_get_header(&self, hash: Hash) -> ConsensusResult<Arc<Header>> {
        self.clone().spawn_blocking(move |c| c.get_header(hash)).await
    }

    pub async fn async_get_headers_selected_tip(&self) -> Hash {
'@
$sessionNew = @'
    pub async fn async_get_header(&self, hash: Hash) -> ConsensusResult<Arc<Header>> {
        self.clone().spawn_blocking(move |c| c.get_header(hash)).await
    }

    pub async fn async_get_headers(&self, hashes: Vec<Hash>) -> ConsensusResult<Vec<Arc<Header>>> {
        self.clone().spawn_blocking(move |c| c.get_headers(hashes)).await
    }

    pub async fn async_get_headers_selected_tip(&self) -> Hash {
'@
Replace-Once $sessionPath $sessionOld $sessionNew 'ConsensusProxy async_get_headers insertion'

# 4a) Trusted pruning-anticone body-only path: request the bodies, then fetch the matching header
# chunk once while the peer can already be filling the incoming route.
$flowPath = 'protocol/flows/src/ibd/flow.rs'
$trustedOld = @'
            let mut jobs = Vec::with_capacity(chunk.len());

            for &hash in chunk.iter() {
                let msg = dequeue_with_timeout!(self.incoming_route, Payload::BlockBody)?;
                // Header first: compact v11 proofs derive their seed/tree shape from it.
                // TODO (relaxed): make header queries in a batch.
                let blk_header = consensus.async_get_header(hash).await.map_err(|err| {
                    ProtocolError::OtherOwned(format!("syncee inconsistency: missing block header for {}, err: {}", hash, err))
                })?;
'@
$trustedNew = @'
            let mut jobs = Vec::with_capacity(chunk.len());
            let headers = consensus.async_get_headers(chunk.to_vec()).await.map_err(|err| {
                ProtocolError::OtherOwned(format!("syncee inconsistency: missing trusted block header in batch, err: {}", err))
            })?;
            if headers.len() != chunk.len() {
                return Err(ProtocolError::Other("consensus returned a truncated trusted-header batch"));
            }

            for (&hash, blk_header) in chunk.iter().zip(headers.into_iter()) {
                if blk_header.hash != hash {
                    return Err(ProtocolError::OtherOwned(format!(
                        "consensus returned header {} while trusted body {} was requested",
                        blk_header.hash, hash
                    )));
                }
                let msg = dequeue_with_timeout!(self.incoming_route, Payload::BlockBody)?;
'@
Replace-Once $flowPath $trustedOld $trustedNew 'trusted body-only header batching'

# 4b) Normal body-only IBD path: same ordered prefetch, eliminating up to IBD_BATCH_SIZE
# independent spawn_blocking calls per network chunk.
$bodyOld = @'
        for &expected_hash in chunk {
            let wait_started = metrics_enabled().then(Instant::now);
            let msg = dequeue_with_timeout!(self.incoming_route, Payload::BlockBody)?;
            if let Some(wait_started) = wait_started {
                pom.peer_wait_time = pom.peer_wait_time.saturating_add(wait_started.elapsed());
            }
            let proof_bytes = if metrics_enabled() {
                msg.pom_proof.as_ref().or(msg.pom_proof_deduped.as_ref()).map(|proof| proof.len() as u64).unwrap_or(0)
            } else {
                0
            };
            if proof_bytes > 0 {
                pom.proofs = pom.proofs.saturating_add(1);
                pom.proof_bytes = pom.proof_bytes.saturating_add(proof_bytes);
            }
            // Capture the proven tier and possession proof before consuming `msg`. The tier is
            // needed to validate the coinbase tier-reward split; the proof must be persisted so this
            // block can later be relayed to proof-enforcing peers (otherwise it is served "naked"
            // and rejected with "PoM possession proof missing").
            let pom_tier = msg.pom_tier.map(|t| t as u8);
            let decode_started = metrics_enabled().then(Instant::now);
            // Header first: compact v11 proofs derive their seed/tree shape from it.
            // TODO (relaxed): make header queries in a batch.
            let blk_header = consensus.async_get_header(expected_hash).await.map_err(|err| {
                ProtocolError::OtherOwned(format!("syncee inconsistency: missing block header for {}, err: {}", expected_hash, err))
            })?;
'@
$bodyNew = @'
        let headers = consensus.async_get_headers(chunk.to_vec()).await.map_err(|err| {
            ProtocolError::OtherOwned(format!("syncee inconsistency: missing block header in body batch, err: {}", err))
        })?;
        if headers.len() != chunk.len() {
            return Err(ProtocolError::Other("consensus returned a truncated body-sync header batch"));
        }

        for (&expected_hash, blk_header) in chunk.iter().zip(headers.into_iter()) {
            if blk_header.hash != expected_hash {
                return Err(ProtocolError::OtherOwned(format!(
                    "consensus returned header {} while body {} was requested",
                    blk_header.hash, expected_hash
                )));
            }
            let wait_started = metrics_enabled().then(Instant::now);
            let msg = dequeue_with_timeout!(self.incoming_route, Payload::BlockBody)?;
            if let Some(wait_started) = wait_started {
                pom.peer_wait_time = pom.peer_wait_time.saturating_add(wait_started.elapsed());
            }
            let proof_bytes = if metrics_enabled() {
                msg.pom_proof.as_ref().or(msg.pom_proof_deduped.as_ref()).map(|proof| proof.len() as u64).unwrap_or(0)
            } else {
                0
            };
            if proof_bytes > 0 {
                pom.proofs = pom.proofs.saturating_add(1);
                pom.proof_bytes = pom.proof_bytes.saturating_add(proof_bytes);
            }
            // Capture the proven tier and possession proof before consuming `msg`. The tier is
            // needed to validate the coinbase tier-reward split; the proof must be persisted so this
            // block can later be relayed to proof-enforcing peers (otherwise it is served "naked"
            // and rejected with "PoM possession proof missing").
            let pom_tier = msg.pom_tier.map(|t| t as u8);
            let decode_started = metrics_enabled().then(Instant::now);
'@
Replace-Once $flowPath $bodyOld $bodyNew 'normal body-only header batching'

$changed = @(
    'consensus/core/src/api/mod.rs',
    'consensus/src/consensus/mod.rs',
    'components/consensusmanager/src/session.rs',
    'protocol/flows/src/ibd/flow.rs'
)

Write-Host 'Formatting Phase 4.2 candidate...'
rustfmt --edition 2024 --config skip_children=true 'consensus/core/src/api/mod.rs'
if ($LASTEXITCODE -ne 0) { throw 'rustfmt failed for consensus API' }
rustfmt --edition 2024 --config skip_children=true 'consensus/src/consensus/mod.rs'
if ($LASTEXITCODE -ne 0) { throw 'rustfmt failed for consensus implementation' }
rustfmt --edition 2024 'components/consensusmanager/src/session.rs'
if ($LASTEXITCODE -ne 0) { throw 'rustfmt failed for consensus session' }
rustfmt --edition 2024 'protocol/flows/src/ibd/flow.rs'
if ($LASTEXITCODE -ne 0) { throw 'rustfmt failed for IBD flow' }

git diff --check
if ($LASTEXITCODE -ne 0) { throw 'git diff --check failed' }

$actualChanged = @(git diff --name-only)
$unexpected = @($actualChanged | Where-Object { $_ -notin $changed })
if ($unexpected.Count -ne 0) { throw "unexpected Phase 4.2 source changes: $($unexpected -join ', ')" }
foreach ($file in $changed) {
    if ($file -notin $actualChanged) { throw "expected Phase 4.2 file was not changed: $file" }
}

$flow = Read-Text $flowPath
$session = Read-Text $sessionPath
$api = Read-Text $apiPath
if (([regex]::Matches($flow, 'async_get_headers\(')).Count -ne 2) { throw 'expected exactly two body-sync async_get_headers calls' }
if ($flow.Contains('TODO (relaxed): make header queries in a batch.')) { throw 'old per-block header batching TODO still present' }
if (-not $session.Contains('pub async fn async_get_headers')) { throw 'async_get_headers proxy guard missing' }
if (-not $api.Contains('fn get_headers(&self, hashes: Vec<Hash>)')) { throw 'ConsensusApi get_headers guard missing' }

Write-Host 'Running Phase 4.2 compile gates...'
cargo check -p keryx-consensus-core --all-targets
if ($LASTEXITCODE -ne 0) { throw 'consensus-core check failed' }
cargo check -p keryx-consensus --all-targets
if ($LASTEXITCODE -ne 0) { throw 'consensus check failed' }
cargo check -p keryx-consensusmanager --all-targets
if ($LASTEXITCODE -ne 0) { throw 'consensusmanager check failed' }
cargo check -p keryx-p2p-flows --all-targets
if ($LASTEXITCODE -ne 0) { throw 'p2p-flows check failed' }
cargo check -p keryxd --all-targets
if ($LASTEXITCODE -ne 0) { throw 'keryxd check failed' }

Write-Host 'Running Phase 4.2 Clippy gates...'
cargo clippy -p keryx-consensusmanager --all-targets --no-deps -- -D warnings
if ($LASTEXITCODE -ne 0) { throw 'consensusmanager Clippy failed' }
# v1.5.6 baseline findings outside Phase 4.2 remain allowed only for these two categories.
cargo clippy -p keryx-p2p-flows --all-targets --no-deps -- -D warnings -A clippy::type-complexity -A clippy::collapsible-if
if ($LASTEXITCODE -ne 0) { throw 'p2p-flows Clippy failed' }

Write-Host 'Running Phase 4.2 regression tests...'
cargo test -p keryx-p2p-flows ibd_v2
if ($LASTEXITCODE -ne 0) { throw 'IBD v2 regression tests failed' }
cargo test -p keryx-consensus pruning_point_utxo_import_replay_is_idempotent
if ($LASTEXITCODE -ne 0) { throw 'UTXO replay regression failed' }

Write-Host 'Building Phase 4.2 release node...'
cargo build --release -p keryxd
if ($LASTEXITCODE -ne 0) { throw 'release build failed' }

# Guard the inherited v1.5.6 / IBD v2 work as well as the new batch API.
$flow = Read-Text $flowPath
foreach ($needle in @('decode_pom_proof', 'pom_proof_min_daa', 'ServiceStateRecovery', 'UtxoRecovery', 'IbdStageTracker', 'get_missing_block_body_hashes_batch', 'async_get_headers')) {
    if (-not $flow.Contains($needle)) { throw "Phase 4.2 integration guard lost: $needle" }
}

# Publish only after all checks pass.
git config user.name 'Keryx IBD V2 Local Runner'
git config user.email 'actions@localhost'
git add -- $changed
git commit -m 'perf(ibd-v2): batch body-sync header reads'
if ($LASTEXITCODE -ne 0) { throw 'functional Phase 4.2 commit failed' }
$sha = (git rev-parse HEAD).Trim()
Write-Host "PHASE4_2_HEAD=$sha"
git push origin HEAD:$branch
if ($LASTEXITCODE -ne 0) { throw 'Phase 4.2 push failed' }

$exe = Join-Path $PWD 'target\release\keryxd.exe'
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash.ToLowerInvariant()
Write-Host "keryxd.exe SHA256=$hash"
