$ErrorActionPreference = 'Stop'

$branch = 'ibd-v2-phase4-db-batching'
$phase42 = '37801a265330f1131eabf07ff1d7b48c231fffa6'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-Text([string]$Path) {
    [IO.File]::ReadAllText((Resolve-Path $Path))
}

function Write-Text([string]$Path, [string]$Text, [bool]$UseCrlf) {
    if ($UseCrlf) {
        $Text = $Text.Replace("`r`n", "`n").Replace("`n", "`r`n")
    } else {
        $Text = $Text.Replace("`r`n", "`n")
    }
    [IO.File]::WriteAllText((Resolve-Path $Path), $Text, $utf8NoBom)
}

function Replace-Once([string]$Path, [string]$Old, [string]$New, [string]$Label) {
    $raw = Read-Text $Path
    $usesCrlf = $raw.Contains("`r`n")
    $text = $raw.Replace("`r`n", "`n")
    $oldNormalized = $Old.Replace("`r`n", "`n")
    $newNormalized = $New.Replace("`r`n", "`n")
    $first = $text.IndexOf($oldNormalized, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "${Label}: source marker not found in $Path" }
    $second = $text.IndexOf($oldNormalized, $first + $oldNormalized.Length, [StringComparison]::Ordinal)
    if ($second -ge 0) { throw "${Label}: source marker occurs more than once in $Path" }
    $text = $text.Substring(0, $first) + $newNormalized + $text.Substring($first + $oldNormalized.Length)
    Write-Text $Path $text $usesCrlf
}

$head = (git rev-parse HEAD).Trim()
git merge-base --is-ancestor $phase42 $head
if ($LASTEXITCODE -ne 0) { throw "Phase 4.2 functional commit $phase42 is not an ancestor of HEAD $head" }
$dirty = @(git status --porcelain --untracked-files=no)
if ($dirty.Count -ne 0) { throw "tracked source tree is dirty before Phase 4.3 patch: $($dirty -join '; ')" }

# 1) Ghostdag store: expose an ordered batch API. The DB implementation overrides the default
# reader loop and delegates to CachedDbAccess::read_many, which serves cache hits first and performs
# one RocksDB multi_get for all misses.
$ghostdagPath = 'consensus/src/model/stores/ghostdag.rs'
$traitOld = @'
    /// Returns full block data for the requested hash
    fn get_data(&self, hash: Hash) -> Result<Arc<GhostdagData>, StoreError>;

    fn get_compact_data(&self, hash: Hash) -> Result<CompactGhostdagData, StoreError>;
'@
$traitNew = @'
    /// Returns full block data for the requested hash
    fn get_data(&self, hash: Hash) -> Result<Arc<GhostdagData>, StoreError>;

    /// Returns one ordered slot per requested hash. `None` means the hash has no full Ghostdag
    /// record. Implementations may override this to use a native database batch read.
    fn get_data_batch(&self, hashes: &[Hash]) -> Result<Vec<Option<Arc<GhostdagData>>>, StoreError> {
        hashes
            .iter()
            .copied()
            .map(|hash| if self.has(hash)? { self.get_data(hash).map(Some) } else { Ok(None) })
            .collect()
    }

    fn get_compact_data(&self, hash: Hash) -> Result<CompactGhostdagData, StoreError>;
'@
Replace-Once $ghostdagPath $traitOld $traitNew 'GhostdagStoreReader batch API insertion'

$dbOld = @'
    fn get_data(&self, hash: Hash) -> Result<Arc<GhostdagData>, StoreError> {
        self.access.read(hash)
    }

    fn get_compact_data(&self, hash: Hash) -> Result<CompactGhostdagData, StoreError> {
'@
$dbNew = @'
    fn get_data(&self, hash: Hash) -> Result<Arc<GhostdagData>, StoreError> {
        self.access.read(hash)
    }

    fn get_data_batch(&self, hashes: &[Hash]) -> Result<Vec<Option<Arc<GhostdagData>>>, StoreError> {
        self.access.read_many(hashes).map(|(values, _, _)| values)
    }

    fn get_compact_data(&self, hash: Hash) -> Result<CompactGhostdagData, StoreError> {
'@
Replace-Once $ghostdagPath $dbOld $dbNew 'DbGhostdagStore multi_get implementation'

# 2) Consensus API: ordered external Ghostdag batch lookup.
$apiPath = 'consensus/core/src/api/mod.rs'
$apiOld = @'
    fn get_ghostdag_data(&self, hash: Hash) -> ConsensusResult<ExternalGhostdagData> {
        unimplemented!()
    }

    fn get_block_children(&self, hash: Hash) -> Option<Vec<Hash>> {
'@
$apiNew = @'
    fn get_ghostdag_data(&self, hash: Hash) -> ConsensusResult<ExternalGhostdagData> {
        unimplemented!()
    }

    /// Returns Ghostdag data in exactly the same order as `hashes`. The first hash with a missing
    /// or invalid status retains the same error semantics as `get_ghostdag_data`.
    fn get_ghostdag_data_batch(&self, hashes: Vec<Hash>) -> ConsensusResult<Vec<ExternalGhostdagData>> {
        unimplemented!()
    }

    fn get_block_children(&self, hash: Hash) -> Option<Vec<Hash>> {
'@
Replace-Once $apiPath $apiOld $apiNew 'ConsensusApi Ghostdag batch insertion'

# 3) Concrete consensus: preserve the existing per-hash status semantics, then issue one Ghostdag
# store batch read. Status batching is intentionally deferred to Phase 4.4.
$consensusPath = 'consensus/src/consensus/mod.rs'
$consensusOld = @'
    fn get_ghostdag_data(&self, hash: Hash) -> ConsensusResult<ExternalGhostdagData> {
        match self.get_block_status(hash) {
            None => return Err(ConsensusError::HeaderNotFound(hash)),
            Some(BlockStatus::StatusInvalid) => return Err(ConsensusError::InvalidBlock(hash)),
            _ => {}
        };
        let ghostdag = self.ghostdag_store.get_data(hash).optional().unwrap().ok_or(ConsensusError::MissingData(hash))?;
        Ok((&*ghostdag).into())
    }

    fn get_block_children(&self, hash: Hash) -> Option<Vec<Hash>> {
'@
$consensusNew = @'
    fn get_ghostdag_data(&self, hash: Hash) -> ConsensusResult<ExternalGhostdagData> {
        match self.get_block_status(hash) {
            None => return Err(ConsensusError::HeaderNotFound(hash)),
            Some(BlockStatus::StatusInvalid) => return Err(ConsensusError::InvalidBlock(hash)),
            _ => {}
        };
        let ghostdag = self.ghostdag_store.get_data(hash).optional().unwrap().ok_or(ConsensusError::MissingData(hash))?;
        Ok((&*ghostdag).into())
    }

    fn get_ghostdag_data_batch(&self, hashes: Vec<Hash>) -> ConsensusResult<Vec<ExternalGhostdagData>> {
        for &hash in &hashes {
            match self.get_block_status(hash) {
                None => return Err(ConsensusError::HeaderNotFound(hash)),
                Some(BlockStatus::StatusInvalid) => return Err(ConsensusError::InvalidBlock(hash)),
                _ => {}
            }
        }

        let ghostdags = self.ghostdag_store.get_data_batch(&hashes).unwrap();
        hashes
            .into_iter()
            .zip(ghostdags)
            .map(|(hash, ghostdag)| {
                let ghostdag = ghostdag.ok_or(ConsensusError::MissingData(hash))?;
                Ok((&*ghostdag).into())
            })
            .collect()
    }

    fn get_block_children(&self, hash: Hash) -> Option<Vec<Hash>> {
'@
Replace-Once $consensusPath $consensusOld $consensusNew 'Consensus Ghostdag batch implementation'

# 4) Async proxy: one spawn_blocking for the complete ordered Ghostdag chunk.
$sessionPath = 'components/consensusmanager/src/session.rs'
$sessionOld = @'
    pub async fn async_get_ghostdag_data(&self, hash: Hash) -> ConsensusResult<ExternalGhostdagData> {
        self.clone().spawn_blocking(move |c| c.get_ghostdag_data(hash)).await
    }

    pub async fn async_get_block_children(&self, hash: Hash) -> Option<Vec<Hash>> {
'@
$sessionNew = @'
    pub async fn async_get_ghostdag_data(&self, hash: Hash) -> ConsensusResult<ExternalGhostdagData> {
        self.clone().spawn_blocking(move |c| c.get_ghostdag_data(hash)).await
    }

    pub async fn async_get_ghostdag_data_batch(&self, hashes: Vec<Hash>) -> ConsensusResult<Vec<ExternalGhostdagData>> {
        self.clone().spawn_blocking(move |c| c.get_ghostdag_data_batch(hashes)).await
    }

    pub async fn async_get_block_children(&self, hash: Hash) -> Option<Vec<Hash>> {
'@
Replace-Once $sessionPath $sessionOld $sessionNew 'ConsensusProxy Ghostdag batch insertion'

# 5a) Trusted body-only path: fetch headers and Ghostdag metadata once per chunk before consuming
# network bodies. Both ordered batches are length-checked; the header batch additionally binds hash
# identity because ExternalGhostdagData intentionally does not carry its own block hash.
$flowPath = 'protocol/flows/src/ibd/flow.rs'
$trustedOld = @'
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
$trustedNew = @'
            if headers.len() != chunk.len() {
                return Err(ProtocolError::Other("consensus returned a truncated trusted-header batch"));
            }
            let ghostdags = consensus.async_get_ghostdag_data_batch(chunk.to_vec()).await.map_err(|err| {
                ProtocolError::OtherOwned(format!("syncee inconsistency: missing trusted Ghostdag data in batch, err: {}", err))
            })?;
            if ghostdags.len() != chunk.len() {
                return Err(ProtocolError::Other("consensus returned a truncated trusted-Ghostdag batch"));
            }

            for ((&hash, blk_header), ghostdag) in chunk.iter().zip(headers.into_iter()).zip(ghostdags.into_iter()) {
                if blk_header.hash != hash {
                    return Err(ProtocolError::OtherOwned(format!(
                        "consensus returned header {} while trusted body {} was requested",
                        blk_header.hash, hash
                    )));
                }
                let msg = dequeue_with_timeout!(self.incoming_route, Payload::BlockBody)?;
'@
Replace-Once $flowPath $trustedOld $trustedNew 'trusted body-only Ghostdag prefetch'

$trustedUseOld = @'
                jobs.push(
                    consensus
                        .validate_and_insert_trusted_block(TrustedBlock::new(block, consensus.async_get_ghostdag_data(hash).await?))
                        .virtual_state_task,
                );
'@
$trustedUseNew = @'
                jobs.push(consensus.validate_and_insert_trusted_block(TrustedBlock::new(block, ghostdag)).virtual_state_task);
'@
# The same block appears twice (body-only and full-block), so replace only after making the second
# path structurally distinct below. First replace the body-only occurrence by operating on the
# prefix ending at the next function declaration.
$rawFlow = Read-Text $flowPath
$usesCrlf = $rawFlow.Contains("`r`n")
$normalizedFlow = $rawFlow.Replace("`r`n", "`n")
$boundary = '    async fn sync_missing_trusted_bodies_full_blocks('
$boundaryIndex = $normalizedFlow.IndexOf($boundary, [StringComparison]::Ordinal)
if ($boundaryIndex -lt 0) { throw 'trusted full-block function boundary not found' }
$prefix = $normalizedFlow.Substring(0, $boundaryIndex)
$suffix = $normalizedFlow.Substring($boundaryIndex)
$oldNormalized = $trustedUseOld.Replace("`r`n", "`n")
$newNormalized = $trustedUseNew.Replace("`r`n", "`n")
$first = $prefix.IndexOf($oldNormalized, [StringComparison]::Ordinal)
if ($first -lt 0) { throw 'trusted body-only per-block Ghostdag call not found' }
if ($prefix.IndexOf($oldNormalized, $first + $oldNormalized.Length, [StringComparison]::Ordinal) -ge 0) {
    throw 'trusted body-only per-block Ghostdag call occurs more than once'
}
$prefix = $prefix.Substring(0, $first) + $newNormalized + $prefix.Substring($first + $oldNormalized.Length)
Write-Text $flowPath ($prefix + $suffix) $usesCrlf

# 5b) Trusted full-block path: prefetch Ghostdag data once for the whole chunk and zip it with the
# expected hashes. No network or consensus validation semantics are changed.
$fullOld = @'
            let mut jobs = Vec::with_capacity(chunk.len());

            for &hash in chunk.iter() {
                // TODO: change to BodyOnly requests when incorporated
'@
$fullNew = @'
            let mut jobs = Vec::with_capacity(chunk.len());
            let ghostdags = consensus.async_get_ghostdag_data_batch(chunk.to_vec()).await.map_err(|err| {
                ProtocolError::OtherOwned(format!("syncee inconsistency: missing trusted Ghostdag data in batch, err: {}", err))
            })?;
            if ghostdags.len() != chunk.len() {
                return Err(ProtocolError::Other("consensus returned a truncated trusted-Ghostdag batch"));
            }

            for (&hash, ghostdag) in chunk.iter().zip(ghostdags.into_iter()) {
                // TODO: change to BodyOnly requests when incorporated
'@
Replace-Once $flowPath $fullOld $fullNew 'trusted full-block Ghostdag prefetch'

# Only one old per-block Ghostdag call should remain now: the full-block trusted path.
Replace-Once $flowPath $trustedUseOld $trustedUseNew 'trusted full-block per-block Ghostdag removal'

$changed = @(
    'consensus/src/model/stores/ghostdag.rs',
    'consensus/core/src/api/mod.rs',
    'consensus/src/consensus/mod.rs',
    'components/consensusmanager/src/session.rs',
    'protocol/flows/src/ibd/flow.rs'
)

Write-Host 'Formatting Phase 4.3 candidate...'
rustfmt --edition 2024 'consensus/src/model/stores/ghostdag.rs'
if ($LASTEXITCODE -ne 0) { throw 'rustfmt failed for Ghostdag store' }
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
if ($unexpected.Count -ne 0) { throw "unexpected Phase 4.3 source changes: $($unexpected -join ', ')" }
foreach ($file in $changed) {
    if ($file -notin $actualChanged) { throw "expected Phase 4.3 file was not changed: $file" }
}

$flow = Read-Text $flowPath
$ghostdag = Read-Text $ghostdagPath
$session = Read-Text $sessionPath
$api = Read-Text $apiPath
if (([regex]::Matches($flow, 'async_get_ghostdag_data_batch\(')).Count -ne 2) { throw 'expected exactly two trusted-path Ghostdag batch calls' }
if (([regex]::Matches($flow, 'TrustedBlock::new\(block, consensus\.async_get_ghostdag_data\(hash\)\.await\?\)')).Count -ne 0) {
    throw 'trusted paths still contain per-block async Ghostdag calls'
}
if (-not $ghostdag.Contains('self.access.read_many(hashes)')) { throw 'DbGhostdagStore does not use CachedDbAccess::read_many' }
if (-not $session.Contains('pub async fn async_get_ghostdag_data_batch')) { throw 'async Ghostdag batch proxy guard missing' }
if (-not $api.Contains('fn get_ghostdag_data_batch(&self, hashes: Vec<Hash>)')) { throw 'ConsensusApi Ghostdag batch guard missing' }

Write-Host 'Running Phase 4.3 compile gates...'
cargo check -p keryx-database --all-targets
if ($LASTEXITCODE -ne 0) { throw 'database check failed' }
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

Write-Host 'Running Phase 4.3 Clippy gates...'
cargo clippy -p keryx-consensusmanager --all-targets --no-deps -- -D warnings
if ($LASTEXITCODE -ne 0) { throw 'consensusmanager Clippy failed' }
cargo clippy -p keryx-p2p-flows --all-targets --no-deps -- -D warnings -A clippy::type-complexity -A clippy::collapsible-if
if ($LASTEXITCODE -ne 0) { throw 'p2p-flows Clippy failed' }

Write-Host 'Running Phase 4.3 regressions...'
cargo test -p keryx-p2p-flows ibd_v2
if ($LASTEXITCODE -ne 0) { throw 'IBD v2 regression tests failed' }
cargo test -p keryx-consensus pruning_point_utxo_import_replay_is_idempotent
if ($LASTEXITCODE -ne 0) { throw 'UTXO replay regression failed' }
cargo test -p keryx-consensus model::stores::ghostdag::tests::test_mergeset_iterators
if ($LASTEXITCODE -ne 0) { throw 'Ghostdag store regression failed' }

Write-Host 'Building Phase 4.3 release node...'
cargo build --release -p keryxd
if ($LASTEXITCODE -ne 0) { throw 'release build failed' }

# Preserve all earlier v1.5.6 / IBD v2 integrations and both DB batch APIs.
$flow = Read-Text $flowPath
foreach ($needle in @('decode_pom_proof', 'pom_proof_min_daa', 'ServiceStateRecovery', 'UtxoRecovery', 'IbdStageTracker', 'get_missing_block_body_hashes_batch', 'async_get_headers', 'async_get_ghostdag_data_batch')) {
    if (-not $flow.Contains($needle)) { throw "Phase 4.3 integration guard lost: $needle" }
}

# Publish functional code only after every check is green.
git config user.name 'Keryx IBD V2 Local Runner'
git config user.email 'actions@localhost'
git add -- $changed
git commit -m 'perf(ibd-v2): batch trusted Ghostdag reads'
if ($LASTEXITCODE -ne 0) { throw 'functional Phase 4.3 commit failed' }
$sha = (git rev-parse HEAD).Trim()
Write-Host "PHASE4_3_HEAD=$sha"
git push origin HEAD:$branch
if ($LASTEXITCODE -ne 0) { throw 'Phase 4.3 push failed' }

$exe = Join-Path $PWD 'target\release\keryxd.exe'
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash.ToLowerInvariant()
Write-Host "keryxd.exe SHA256=$hash"
