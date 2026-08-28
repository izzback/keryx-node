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

Write-Host 'Installing protoc 29.6 and Rust 1.93.0 for the local certification run...'
$protocVersion = '29.6'
$protocArchive = Join-Path $env:RUNNER_TEMP "protoc-$protocVersion-win64.zip"
$protocRoot = Join-Path $env:RUNNER_TEMP "protoc-$protocVersion-accelerate"
if (Test-Path $protocRoot) { Remove-Item $protocRoot -Recurse -Force }
New-Item -ItemType Directory -Path $protocRoot -Force | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/protocolbuffers/protobuf/releases/download/v$protocVersion/protoc-$protocVersion-win64.zip" -OutFile $protocArchive
Expand-Archive -LiteralPath $protocArchive -DestinationPath $protocRoot -Force
$protocBin = Join-Path $protocRoot 'bin'
$env:PATH = "$protocBin;$env:PATH"
& (Join-Path $protocBin 'protoc.exe') --version
if ($LASTEXITCODE -ne 0) { throw 'protoc install failed' }

$rustRoot = Join-Path $env:RUNNER_TEMP 'rust-1.93.0-accelerate'
$cargoHome = Join-Path $rustRoot 'cargo'
$rustupHome = Join-Path $rustRoot 'rustup'
$rustupInit = Join-Path $env:RUNNER_TEMP 'rustup-init-accelerate.exe'
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

Write-Host 'Applying Phase 3 crash-safety patch...'
Write-Lf 'protocol/flows/src/ibd_v2/fault_injection.rs' @'
//! Explicit, opt-in crash injection for Phase 3 recovery testing.
//!
//! This is intentionally inert unless IBD v2 itself is enabled AND the dedicated
//! fault-injection switch is truthy. Production users therefore cannot trigger a
//! crash merely by setting a point name accidentally.

pub const ENABLE_ENV: &str = "KERYX_IBD_V2_FAULT_INJECTION";
pub const POINT_ENV: &str = "KERYX_IBD_V2_FAULT_POINT";

fn truthy(value: &str) -> bool {
    matches!(value.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on")
}

pub fn requested(point: &str) -> bool {
    if !super::enabled_from_env() {
        return false;
    }
    let enabled = std::env::var(ENABLE_ENV).map(|value| truthy(&value)).unwrap_or(false);
    if !enabled {
        return false;
    }
    std::env::var(POINT_ENV).map(|value| value.trim().eq_ignore_ascii_case(point)).unwrap_or(false)
}

/// Abort the whole process at an exact durability boundary when explicitly requested.
/// `abort()` is deliberate: Phase 3 needs to prove recovery after a hard process loss,
/// without graceful shutdown handlers being given a chance to repair state.
pub fn crash_if_requested(point: &'static str) {
    if requested(point) {
        keryx_core::warn!("IBD v2 fault injection: aborting at {}", point);
        std::process::abort();
    }
}

#[cfg(test)]
mod tests {
    use super::truthy;

    #[test]
    fn truthy_parser_is_strict_and_case_insensitive() {
        for value in ["1", "true", "TRUE", " yes ", "On"] {
            assert!(truthy(value));
        }
        for value in ["", "0", "false", "enabled", "2"] {
            assert!(!truthy(value));
        }
    }
}
'@

Replace-Once 'protocol/flows/src/ibd_v2/mod.rs' @'
pub mod compat;
pub mod metrics;
'@ @'
pub mod compat;
pub mod fault_injection;
pub mod metrics;
'@

Replace-Once 'protocol/flows/src/ibd_v2/service_state_recovery.rs' @'
        let metadata = self.spool.append_chunk(start_cursor, next_cursor, rows)?;
        self.checkpoint.service_state = Some(metadata);
'@ @'
        let metadata = self.spool.append_chunk(start_cursor, next_cursor, rows)?;
        // The spool fsync is the durability boundary. A crash here must recover
        // by reconciling a lagging checkpoint from the durable spool.
        super::fault_injection::crash_if_requested("service-state-after-spool-fsync");
        self.checkpoint.service_state = Some(metadata);
'@

Replace-Once 'protocol/flows/src/ibd_v2/service_state_recovery.rs' @'
        self.persist()?;
        Ok(metadata)
'@ @'
        self.persist()?;
        super::fault_injection::crash_if_requested("service-state-after-checkpoint");
        Ok(metadata)
'@

Replace-Once 'protocol/flows/src/ibd/flow.rs' @'
        if let Some(recovery) = &mut recovery {
            recovery
                .mark_verified()
                .map_err(|err| ProtocolError::OtherOwned(format!("failed to checkpoint verified IBD v2 service state: {err}")))?;
        }

        let total_rows = rows.len();
'@ @'
        if let Some(recovery) = &mut recovery {
            recovery
                .mark_verified()
                .map_err(|err| ProtocolError::OtherOwned(format!("failed to checkpoint verified IBD v2 service state: {err}")))?;
        }
        crate::ibd_v2::fault_injection::crash_if_requested("service-state-after-verified");

        let total_rows = rows.len();
'@

Replace-Once 'protocol/flows/src/ibd/flow.rs' @'
        consensus.clone().spawn_blocking(move |c| c.import_service_state(rows)).await?;
        if let Some(storage_started) = storage_started {
'@ @'
        consensus.clone().spawn_blocking(move |c| c.import_service_state(rows)).await?;
        crate::ibd_v2::fault_injection::crash_if_requested("service-state-after-import");
        if let Some(storage_started) = storage_started {
'@

Replace-Once 'consensus/src/model/stores/service_burn.rs' @'
use keryx_database::prelude::{CachedDbAccess, CachePolicy, DirectDbWriter, StoreError, DB};
use keryx_database::registry::DatabaseStorePrefixes;
'@ @'
use keryx_database::prelude::{BatchDbWriter, CachedDbAccess, CachePolicy, DirectDbWriter, StoreError, DB};
use keryx_database::registry::DatabaseStorePrefixes;
use rocksdb::WriteBatch;
'@
Replace-Once 'consensus/src/model/stores/service_burn.rs' @'
    pub fn set(&self, key: OutpointKey, miss_daa: u64) -> Result<(), StoreError> {
        self.access.write(DirectDbWriter::new(&self.db), key, miss_daa)
    }

'@ @'
    pub fn set(&self, key: OutpointKey, miss_daa: u64) -> Result<(), StoreError> {
        self.access.write(DirectDbWriter::new(&self.db), key, miss_daa)
    }

    pub fn set_batch(&self, batch: &mut WriteBatch, key: OutpointKey, miss_daa: u64) -> Result<(), StoreError> {
        self.access.write(BatchDbWriter::new(batch), key, miss_daa)
    }

'@

Replace-Once 'consensus/src/model/stores/service_strike.rs' @'
use keryx_database::prelude::{CachedDbAccess, CachePolicy, DirectDbWriter, StoreError, DB};
use keryx_database::registry::DatabaseStorePrefixes;
use keryx_hashes::Hash;
'@ @'
use keryx_database::prelude::{BatchDbWriter, CachedDbAccess, CachePolicy, DirectDbWriter, StoreError, DB};
use keryx_database::registry::DatabaseStorePrefixes;
use keryx_hashes::Hash;
use rocksdb::WriteBatch;
'@
Replace-Once 'consensus/src/model/stores/service_strike.rs' @'
    pub fn set(&self, daa: u64, miner: Hash, record: StrikeEntry) -> Result<(), StoreError> {
        self.access.write(DirectDbWriter::new(&self.db), StrikeLogKey::new(daa, miner), record)
    }

'@ @'
    pub fn set(&self, daa: u64, miner: Hash, record: StrikeEntry) -> Result<(), StoreError> {
        self.access.write(DirectDbWriter::new(&self.db), StrikeLogKey::new(daa, miner), record)
    }

    pub fn set_batch(&self, batch: &mut WriteBatch, daa: u64, miner: Hash, record: StrikeEntry) -> Result<(), StoreError> {
        self.access.write(BatchDbWriter::new(batch), StrikeLogKey::new(daa, miner), record)
    }

'@

Replace-Once 'consensus/src/model/stores/service_first_seen.rs' @'
use keryx_database::prelude::{CachedDbAccess, CachePolicy, DirectDbWriter, StoreError, DB};
use keryx_database::registry::DatabaseStorePrefixes;
use keryx_hashes::Hash;
'@ @'
use keryx_database::prelude::{BatchDbWriter, CachedDbAccess, CachePolicy, DirectDbWriter, StoreError, DB};
use keryx_database::registry::DatabaseStorePrefixes;
use keryx_hashes::Hash;
use rocksdb::WriteBatch;
'@
Replace-Once 'consensus/src/model/stores/service_first_seen.rs' @'
    pub fn set(&self, miner: Hash, daa: u64) -> Result<(), StoreError> {
        self.access.write(DirectDbWriter::new(&self.db), miner, daa)
    }

'@ @'
    pub fn set(&self, miner: Hash, daa: u64) -> Result<(), StoreError> {
        self.access.write(DirectDbWriter::new(&self.db), miner, daa)
    }

    pub fn set_batch(&self, batch: &mut WriteBatch, miner: Hash, daa: u64) -> Result<(), StoreError> {
        self.access.write(BatchDbWriter::new(batch), miner, daa)
    }

'@

Replace-Once 'consensus/src/model/stores/service_reward.rs' @'
use keryx_database::prelude::{CachePolicy, CachedDbAccess, DB, DirectDbWriter, StoreError};
use keryx_database::registry::DatabaseStorePrefixes;
'@ @'
use keryx_database::prelude::{BatchDbWriter, CachePolicy, CachedDbAccess, DB, DirectDbWriter, StoreError};
use keryx_database::registry::DatabaseStorePrefixes;
use rocksdb::WriteBatch;
'@
Replace-Once 'consensus/src/model/stores/service_reward.rs' @'
    pub fn set(&self, key: RewardKey, entry: RewardEntry) -> Result<(), StoreError> {
        self.access.write(DirectDbWriter::new(&self.db), key, entry)
    }

'@ @'
    pub fn set(&self, key: RewardKey, entry: RewardEntry) -> Result<(), StoreError> {
        self.access.write(DirectDbWriter::new(&self.db), key, entry)
    }

    pub fn set_batch(&self, batch: &mut WriteBatch, key: RewardKey, entry: RewardEntry) -> Result<(), StoreError> {
        self.access.write(BatchDbWriter::new(batch), key, entry)
    }

'@

Replace-Once 'consensus/src/consensus/mod.rs' @'
        for row in parsed {
            match row {
                Row::Burn { tx_id, index, daa } => {
                    self.storage.service_burn_store.set(OutpointKey::new(tx_id, index), daa).unwrap()
                }
                Row::Strike { daa, miner, entry } => self.storage.service_strike_store.set(daa, miner, entry).unwrap(),
                Row::Sighting { miner, daa } => self.storage.service_first_seen_store.set(miner, daa).unwrap(),
                Row::Reward { request_hash, entry } => {
                    self.storage.service_reward_store.set(crate::model::stores::service_reward::RewardKey(request_hash), entry).unwrap()
                }
            }
        }
        // Rebuild every derived RAM view (burned set, suspensions, commitment index, cursor).
'@ @'
        // Commit all Service State columns atomically. This closes the Phase 3 crash window
        // where a process loss could previously leave only a prefix of the four stores written.
        // The individual setters remain deterministic/idempotent, so a verified-spool replay
        // after a crash immediately after this batch is also safe.
        let mut batch = WriteBatch::default();
        for row in parsed {
            match row {
                Row::Burn { tx_id, index, daa } => self
                    .storage
                    .service_burn_store
                    .set_batch(&mut batch, OutpointKey::new(tx_id, index), daa)
                    .unwrap(),
                Row::Strike { daa, miner, entry } => self.storage.service_strike_store.set_batch(&mut batch, daa, miner, entry).unwrap(),
                Row::Sighting { miner, daa } => self.storage.service_first_seen_store.set_batch(&mut batch, miner, daa).unwrap(),
                Row::Reward { request_hash, entry } => self
                    .storage
                    .service_reward_store
                    .set_batch(&mut batch, crate::model::stores::service_reward::RewardKey(request_hash), entry)
                    .unwrap(),
            }
        }
        self.db.write(batch).unwrap();
        // Rebuild every derived RAM view (burned set, suspensions, commitment index, cursor).
'@

Write-Host 'Creating Windows real-test scripts...'
Write-Lf 'scripts/ibd-v2/phase3/START-SERVICE-STATE-CRASH-TEST.ps1' @'
[CmdletBinding()]
param(
    [ValidateSet('service-state-after-spool-fsync','service-state-after-checkpoint','service-state-after-verified','service-state-after-import')]
    [string]$FaultPoint = 'service-state-after-import',
    [string]$NodePath = (Join-Path $PSScriptRoot 'keryxd.exe'),
    [string]$DataDir = 'E:\datanode\keryx-ibd-v2-phase3-realtest',
    [string]$ResultsRoot = (Join-Path $PSScriptRoot 'results-phase3')
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
    Write-Host "Starting hard-crash test at $FaultPoint" -ForegroundColor Yellow
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
if ($found) { Write-Host "Expected hard crash observed at $FaultPoint." -ForegroundColor Green }
else { Write-Warning "Process exited but the expected fault marker was not found. Inspect $resultDir." }
Write-Host "NEXT: .\RESUME-SERVICE-STATE-CRASH-TEST.ps1 -DataDir '$DataDir'" -ForegroundColor Cyan
Write-Host "Evidence: $resultDir"
'@

Write-Lf 'scripts/ibd-v2/phase3/RESUME-SERVICE-STATE-CRASH-TEST.ps1' @'
[CmdletBinding()]
param(
    [string]$NodePath = (Join-Path $PSScriptRoot 'keryxd.exe'),
    [string]$DataDir = 'E:\datanode\keryx-ibd-v2-phase3-realtest'
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
Write-Host 'Resuming SAME datadir with fault injection disabled.' -ForegroundColor Green
Write-Host 'Expected: durable cursor resume or local replay of the Verified spool.'
& $NodePath "--appdir=$DataDir"
exit $LASTEXITCODE
'@

Write-Lf 'scripts/ibd-v2/phase3/INSPECT-PHASE3-RECOVERY.ps1' @'
[CmdletBinding()]
param(
    [string]$DataDir = 'E:\datanode\keryx-ibd-v2-phase3-realtest',
    [string]$ResultsRoot = (Join-Path $PSScriptRoot 'results-phase3')
)
$patterns = @('IBD v2 fault injection','resuming durable service-state','replaying locally verified service-state spool','service-state wire mode=','IBD-V2-METRICS: stage=service-state','imported ','IBD with peer','completed successfully')
$files = @()
if (Test-Path $ResultsRoot) { $files += Get-ChildItem $ResultsRoot -Recurse -File -Filter '*.log' -ErrorAction SilentlyContinue }
if (Test-Path $DataDir) { $files += Get-ChildItem $DataDir -Recurse -File -Filter '*.log' -ErrorAction SilentlyContinue }
$files = $files | Sort-Object FullName -Unique
if (!$files) { throw 'No log files were found.' }
foreach ($file in $files) {
    $matches = Select-String -LiteralPath $file.FullName -Pattern $patterns -SimpleMatch -ErrorAction SilentlyContinue
    if ($matches) {
        Write-Host "`n=== $($file.FullName) ===" -ForegroundColor Cyan
        $matches | Select-Object -Last 100 | ForEach-Object { $_.Line }
    }
}
'@

Write-Lf 'scripts/ibd-v2/phase3/CLEAN-PHASE3-REALTEST.ps1' @'
[CmdletBinding()]
param([string]$DataDir = 'E:\datanode\keryx-ibd-v2-phase3-realtest')
$expected = 'E:\datanode\keryx-ibd-v2-phase3-realtest'
if (![string]::Equals([IO.Path]::GetFullPath($DataDir).TrimEnd('\'), [IO.Path]::GetFullPath($expected).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw "Safety refusal: this cleaner only deletes $expected"
}
if (Get-Process -Name keryxd -ErrorAction SilentlyContinue) { throw 'Stop keryxd before cleaning.' }
$confirmation = Read-Host "Type DELETE-PHASE3 to delete $expected"
if ($confirmation -ne 'DELETE-PHASE3') { Write-Host 'Cancelled.'; exit 1 }
if (Test-Path -LiteralPath $expected) { Remove-Item -LiteralPath $expected -Recurse -Force }
New-Item -ItemType Directory -Path $expected -Force | Out-Null
Write-Host "Clean test datadir ready: $expected" -ForegroundColor Green
'@

Write-Lf 'scripts/ibd-v2/phase3/README-PHASE3-REALTEST.txt' @'
Keryx IBD V2 - Phase 3 real crash/recovery test

Default dedicated datadir:
E:\datanode\keryx-ibd-v2-phase3-realtest

Recommended first test:
1. Stop every other keryxd instance.
2. Run:
   .\START-SERVICE-STATE-CRASH-TEST.ps1 -FaultPoint service-state-after-import
3. The node intentionally hard-aborts after the atomic Service State RocksDB import but before the recovery checkpoint becomes Committed.
4. Restart the SAME datadir:
   .\RESUME-SERVICE-STATE-CRASH-TEST.ps1
5. Expected: the Verified spool is replayed locally, the deterministic atomic import is safe to repeat, recovery is marked Committed, then IBD continues.
6. Inspect evidence:
   .\INSPECT-PHASE3-RECOVERY.ps1

Other fault points:
- service-state-after-spool-fsync: durable spool leads checkpoint; restart reconciles from spool.
- service-state-after-checkpoint: restart requests from the durable saved cursor.
- service-state-after-verified: restart replays verified spool without network redownload.
- service-state-after-import: restart safely replays after the atomic DB batch committed.

Crash run env (set automatically):
KERYX_IBD_V2=1
KERYX_IBD_V2_METRICS=1
KERYX_IBD_V2_FAULT_INJECTION=1
KERYX_IBD_V2_FAULT_POINT=<selected point>
'@

Write-Host 'Formatting candidate...'
cargo fmt -- protocol/flows/src/ibd_v2/fault_injection.rs protocol/flows/src/ibd_v2/mod.rs protocol/flows/src/ibd_v2/service_state_recovery.rs protocol/flows/src/ibd/flow.rs consensus/src/model/stores/service_burn.rs consensus/src/model/stores/service_strike.rs consensus/src/model/stores/service_first_seen.rs consensus/src/model/stores/service_reward.rs consensus/src/consensus/mod.rs
if ($LASTEXITCODE -ne 0) { throw 'cargo fmt failed' }

git config user.name 'izzback'
git config user.email 'poolarismining1@gmail.com'
git add protocol/flows/src/ibd_v2/fault_injection.rs protocol/flows/src/ibd_v2/mod.rs protocol/flows/src/ibd_v2/service_state_recovery.rs protocol/flows/src/ibd/flow.rs consensus/src/model/stores/service_burn.rs consensus/src/model/stores/service_strike.rs consensus/src/model/stores/service_first_seen.rs consensus/src/model/stores/service_reward.rs consensus/src/consensus/mod.rs scripts/ibd-v2/phase3
git commit -m 'feat(ibd-v2): make service-state recovery real-crash testable'
if ($LASTEXITCODE -ne 0) { throw 'candidate commit failed' }
$candidate = (git rev-parse HEAD).Trim()
Write-Host "Candidate commit: $candidate"

Write-Host 'Running consensus check...'
cargo check -p keryx-consensus --all-targets
if ($LASTEXITCODE -ne 0) { throw 'consensus check failed' }
Write-Host 'Running flows check...'
cargo check -p keryx-p2p-flows --all-targets
if ($LASTEXITCODE -ne 0) { throw 'flows check failed' }
Write-Host 'Running keryxd integration check...'
cargo check -p keryxd --all-targets
if ($LASTEXITCODE -ne 0) { throw 'keryxd check failed' }
Write-Host 'Running Clippy...'
cargo clippy -p keryx-p2p-flows --all-targets --no-deps -- -D warnings -A clippy::collapsible_if
if ($LASTEXITCODE -ne 0) { throw 'Clippy failed' }
Write-Host 'Running recovery tests...'
cargo test -p keryx-p2p-flows
if ($LASTEXITCODE -ne 0) { throw 'flows tests failed' }
Write-Host 'Building release node...'
cargo build --release -p keryxd
if ($LASTEXITCODE -ne 0) { throw 'release build failed' }

Write-Host 'Pushing certified code candidate...'
git push origin HEAD:ibd-v2-phase3-persistent-state
if ($LASTEXITCODE -ne 0) { throw 'push failed' }

$out = Join-Path $PWD 'phase3-realtest-artifact'
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Path $out -Force | Out-Null
Copy-Item 'target\release\keryxd.exe' (Join-Path $out 'keryxd.exe')
Copy-Item 'scripts\ibd-v2\phase3\*.ps1' $out
Copy-Item 'scripts\ibd-v2\phase3\README-PHASE3-REALTEST.txt' $out
$hash = (Get-FileHash -Algorithm SHA256 'target\release\keryxd.exe').Hash.ToLowerInvariant()
@(
    'project=Keryx IBD V2 Phase 3',
    "commit=$candidate",
    'base_official=bb408d54ca3992f7f9f4e269507f7603c234d24d',
    'runner=Keryx-Node-Windows-01',
    'ibd_v2_default=off',
    "keryxd_sha256=$hash"
) | Set-Content -Encoding ASCII -LiteralPath (Join-Path $out 'BUILD-MANIFEST.txt')
Write-Host "Certified keryxd SHA256: $hash"
