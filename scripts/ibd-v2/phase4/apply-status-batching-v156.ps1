$ErrorActionPreference = 'Stop'

function Replace-Exact {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Old,
        [Parameter(Mandatory = $true)][string]$New
    )

    $text = [IO.File]::ReadAllText((Resolve-Path $Path))
    if (-not $text.Contains($Old)) {
        throw "expected Phase 4.4 source pattern not found in ${Path}: $Old"
    }
    $updated = $text.Replace($Old, $New)
    if ($updated -eq $text) {
        throw "Phase 4.4 replacement made no change in ${Path}"
    }
    [IO.File]::WriteAllText((Resolve-Path $Path), $updated, (New-Object System.Text.UTF8Encoding($false)))
}

$statusesPath = 'consensus/src/model/stores/statuses.rs'
$statusServicePath = 'consensus/src/model/services/statuses.rs'
$apiPath = 'consensus/core/src/api/mod.rs'
$consensusPath = 'consensus/src/consensus/mod.rs'

Replace-Exact -Path $statusesPath -Old @'
pub trait StatusesStoreReader {
    fn get(&self, hash: Hash) -> StoreResult<BlockStatus>;
    fn has(&self, hash: Hash) -> StoreResult<bool>;
}
'@ -New @'
pub trait StatusesStoreReader {
    fn get(&self, hash: Hash) -> StoreResult<BlockStatus>;
    fn get_many(&self, hashes: &[Hash]) -> StoreResult<Vec<Option<BlockStatus>>>;
    fn has(&self, hash: Hash) -> StoreResult<bool>;
}
'@

Replace-Exact -Path $statusesPath -Old @'
impl StatusesStoreReader for DbStatusesStore {
    fn get(&self, hash: Hash) -> StoreResult<BlockStatus> {
        self.access.read(hash)
    }

    fn has(&self, hash: Hash) -> StoreResult<bool> {
'@ -New @'
impl StatusesStoreReader for DbStatusesStore {
    fn get(&self, hash: Hash) -> StoreResult<BlockStatus> {
        self.access.read(hash)
    }

    fn get_many(&self, hashes: &[Hash]) -> StoreResult<Vec<Option<BlockStatus>>> {
        self.access.read_many(hashes).map(|(statuses, _, _)| statuses)
    }

    fn has(&self, hash: Hash) -> StoreResult<bool> {
'@

Replace-Exact -Path $statusServicePath -Old @'
impl<T: StatusesStoreReader> StatusesStoreReader for MTStatusesService<T> {
    fn get(&self, hash: Hash) -> Result<BlockStatus, StoreError> {
        self.store.read().get(hash)
    }

    fn has(&self, hash: Hash) -> Result<bool, StoreError> {
'@ -New @'
impl<T: StatusesStoreReader> StatusesStoreReader for MTStatusesService<T> {
    fn get(&self, hash: Hash) -> Result<BlockStatus, StoreError> {
        self.store.read().get(hash)
    }

    fn get_many(&self, hashes: &[Hash]) -> Result<Vec<Option<BlockStatus>>, StoreError> {
        self.store.read().get_many(hashes)
    }

    fn has(&self, hash: Hash) -> Result<bool, StoreError> {
'@

Replace-Exact -Path $apiPath -Old @'
    fn get_block_status(&self, hash: Hash) -> Option<BlockStatus> {
        unimplemented!()
    }

    fn get_block_acceptance_data(&self, hash: Hash) -> ConsensusResult<Arc<AcceptanceData>> {
'@ -New @'
    fn get_block_status(&self, hash: Hash) -> Option<BlockStatus> {
        unimplemented!()
    }

    /// Returns statuses in exactly the same order as `hashes`, preserving `None` for missing hashes.
    fn get_block_statuses(&self, hashes: &[Hash]) -> Vec<Option<BlockStatus>> {
        unimplemented!()
    }

    fn get_block_acceptance_data(&self, hash: Hash) -> ConsensusResult<Arc<AcceptanceData>> {
'@

Replace-Exact -Path $consensusPath -Old @'
        for &hash in &hashes {
            match self.get_block_status(hash) {
                None => return Err(ConsensusError::HeaderNotFound(hash)),
                Some(BlockStatus::StatusInvalid) => return Err(ConsensusError::InvalidBlock(hash)),
                _ => {}
            }
        }
'@ -New @'
        for (&hash, status) in hashes.iter().zip(self.get_block_statuses(&hashes)) {
            match status {
                None => return Err(ConsensusError::HeaderNotFound(hash)),
                Some(BlockStatus::StatusInvalid) => return Err(ConsensusError::InvalidBlock(hash)),
                _ => {}
            }
        }
'@

Replace-Exact -Path $consensusPath -Old @'
    fn get_block_status(&self, hash: Hash) -> Option<BlockStatus> {
        self.statuses_store.read().get(hash).optional().unwrap()
    }

    fn get_block_acceptance_data(&self, hash: Hash) -> ConsensusResult<Arc<AcceptanceData>> {
'@ -New @'
    fn get_block_status(&self, hash: Hash) -> Option<BlockStatus> {
        self.statuses_store.read().get(hash).optional().unwrap()
    }

    fn get_block_statuses(&self, hashes: &[Hash]) -> Vec<Option<BlockStatus>> {
        self.statuses_store.read().get_many(hashes).unwrap()
    }

    fn get_block_acceptance_data(&self, hash: Hash) -> ConsensusResult<Arc<AcceptanceData>> {
'@

rustfmt --edition 2024 $statusesPath
if ($LASTEXITCODE -ne 0) { throw 'rustfmt failed for statuses store' }
rustfmt --edition 2024 $statusServicePath
if ($LASTEXITCODE -ne 0) { throw 'rustfmt failed for statuses service' }
rustfmt --edition 2024 --config skip_children=true $apiPath
if ($LASTEXITCODE -ne 0) { throw 'rustfmt failed for consensus API' }
rustfmt --edition 2024 --config skip_children=true $consensusPath
if ($LASTEXITCODE -ne 0) { throw 'rustfmt failed for consensus implementation' }

git diff --check
if ($LASTEXITCODE -ne 0) { throw 'Phase 4.4 git diff --check failed' }

$expectedFiles = @(
    'consensus/core/src/api/mod.rs',
    'consensus/src/consensus/mod.rs',
    'consensus/src/model/services/statuses.rs',
    'consensus/src/model/stores/statuses.rs'
)
$actualFiles = @(git diff --name-only)
$unexpected = @($actualFiles | Where-Object { $_ -notin $expectedFiles })
if ($unexpected.Count -ne 0) {
    throw "unexpected Phase 4.4 source changes: $($unexpected -join ', ')"
}
foreach ($file in $expectedFiles) {
    if ($file -notin $actualFiles) {
        throw "expected Phase 4.4 source change missing: $file"
    }
}

$statuses = [IO.File]::ReadAllText((Resolve-Path $statusesPath))
if (-not $statuses.Contains('fn get_many(&self, hashes: &[Hash]) -> StoreResult<Vec<Option<BlockStatus>>>')) {
    throw 'Phase 4.4 status store batch API guard missing'
}
if (-not $statuses.Contains('self.access.read_many(hashes)')) {
    throw 'Phase 4.4 status store read_many guard missing'
}

$statusService = [IO.File]::ReadAllText((Resolve-Path $statusServicePath))
if (-not $statusService.Contains('self.store.read().get_many(hashes)')) {
    throw 'Phase 4.4 status service batch forwarding guard missing'
}

$api = [IO.File]::ReadAllText((Resolve-Path $apiPath))
if (-not $api.Contains('fn get_block_statuses(&self, hashes: &[Hash]) -> Vec<Option<BlockStatus>>')) {
    throw 'Phase 4.4 consensus status batch API guard missing'
}

$consensus = [IO.File]::ReadAllText((Resolve-Path $consensusPath))
if (-not $consensus.Contains('self.statuses_store.read().get_many(hashes).unwrap()')) {
    throw 'Phase 4.4 consensus status store batch guard missing'
}
if (-not $consensus.Contains('hashes.iter().zip(self.get_block_statuses(&hashes))')) {
    throw 'Phase 4.4 Ghostdag status batch integration guard missing'
}
