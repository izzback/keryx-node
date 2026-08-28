$ErrorActionPreference = 'Stop'
Set-Location (Resolve-Path (Join-Path $PSScriptRoot '..\..'))

Write-Host 'Installing protoc 29.6 and Rust 1.93.0 for final Phase 3 certification...'
$protocVersion = '29.6'
$protocArchive = Join-Path $env:RUNNER_TEMP "protoc-$protocVersion-final.zip"
$protocDir = Join-Path $env:RUNNER_TEMP "protoc-$protocVersion-final"
if (Test-Path $protocDir) { Remove-Item $protocDir -Recurse -Force }
New-Item -ItemType Directory -Path $protocDir -Force | Out-Null
Invoke-WebRequest -Uri "https://github.com/protocolbuffers/protobuf/releases/download/v$protocVersion/protoc-$protocVersion-win64.zip" -OutFile $protocArchive -UseBasicParsing
Expand-Archive -LiteralPath $protocArchive -DestinationPath $protocDir -Force
$env:PATH = "$(Join-Path $protocDir 'bin');$env:PATH"
& protoc --version
if ($LASTEXITCODE -ne 0) { throw 'protoc setup failed' }

$rustRoot = Join-Path $env:RUNNER_TEMP 'rust-1.93.0-final-gaps'
$cargoHome = Join-Path $rustRoot 'cargo'
$rustupHome = Join-Path $rustRoot 'rustup'
$rustupInit = Join-Path $env:RUNNER_TEMP 'rustup-init-final-gaps.exe'
New-Item -ItemType Directory -Path $rustRoot -Force | Out-Null
Invoke-WebRequest -Uri 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe' -OutFile $rustupInit -UseBasicParsing
$env:CARGO_HOME = $cargoHome
$env:RUSTUP_HOME = $rustupHome
& $rustupInit -y --no-modify-path --profile minimal --default-host x86_64-pc-windows-msvc --default-toolchain 1.93.0
if ($LASTEXITCODE -ne 0) { throw 'rustup setup failed' }
$env:PATH = "$(Join-Path $cargoHome 'bin');$env:PATH"
& rustup component add rustfmt clippy --toolchain 1.93.0-x86_64-pc-windows-msvc
if ($LASTEXITCODE -ne 0) { throw 'rust components setup failed' }

Write-Host 'Adding deterministic crash point after durable UTXO Committed checkpoint...'
$flowPath = 'protocol/flows/src/ibd/flow.rs'
$flowText = [IO.File]::ReadAllText((Resolve-Path $flowPath))
$crashLine = '        crate::ibd_v2::fault_injection::crash_if_requested("utxo-after-committed");'
if (-not $flowText.Contains($crashLine)) {
    $marker = '        // Arm Service State before exposing the UTXO stage as stable. A crash after UTXO commit'
    $index = $flowText.IndexOf($marker, [StringComparison]::Ordinal)
    if ($index -lt 0) { throw 'Stable Service State handoff marker not found in flow.rs' }
    $nl = if ($flowText.Contains("`r`n")) { "`r`n" } else { "`n" }
    $insert = @(
        '        // Deterministic coverage for the final UTXO->Service-State handoff window. At this',
        '        // boundary the UTXO checkpoint is already Committed, while Service State is not armed',
        '        // yet. Restart must skip UTXO network replay and arm Service State before stability.',
        '        crate::ibd_v2::fault_injection::crash_if_requested("utxo-after-committed");',
        ''
    ) -join $nl
    $flowText = $flowText.Insert($index, $insert)
    [IO.File]::WriteAllText((Resolve-Path $flowPath),$flowText,(New-Object System.Text.UTF8Encoding($false)))
}

Write-Host 'Exposing utxo-after-committed in the Windows real-test launcher...'
$scriptPath = 'scripts/ibd-v2/phase3/START-UTXO-CRASH-TEST.ps1'
$scriptText = [IO.File]::ReadAllText((Resolve-Path $scriptPath))
if (-not $scriptText.Contains("'utxo-after-committed'")) {
    $scriptText = $scriptText.Replace("'utxo-after-verified','utxo-after-import'", "'utxo-after-verified','utxo-after-import','utxo-after-committed'")
    [IO.File]::WriteAllText((Resolve-Path $scriptPath),$scriptText,(New-Object System.Text.UTF8Encoding($false)))
}

Write-Host 'Adding consensus-level double-import regression test...'
$testsPath = 'consensus/src/pipeline/virtual_processor/tests.rs'
$testsText = [IO.File]::ReadAllText((Resolve-Path $testsPath))
$testMarker = 'async fn pruning_point_utxo_import_replay_is_idempotent()'
if (-not $testsText.Contains($testMarker)) {
$test = @'

/// A crash at `utxo-after-import` happens only after the complete pruning-point import returned
/// successfully but before the filesystem recovery checkpoint is marked Committed. Restarting
/// deliberately invokes the same import again, so replaying an identical verified snapshot must
/// preserve the externally-visible virtual state rather than accumulate derived state.
#[tokio::test]
async fn pruning_point_utxo_import_replay_is_idempotent() {
    use keryx_muhash::MuHash;

    let config = ConfigBuilder::new(MAINNET_PARAMS).skip_proof_of_work().build();
    let ctx = TestContext::new(TestConsensus::new(&config));
    let genesis = ctx.consensus.params().genesis.hash;

    ctx.consensus.import_pruning_point_utxo_set(genesis, MuHash::new()).unwrap();
    let first_sink = ctx.consensus.get_sink();
    let first_parents = ctx.consensus.get_virtual_parents();
    let first_status = ctx.consensus.get_block_status(genesis);

    ctx.consensus.import_pruning_point_utxo_set(genesis, MuHash::new()).unwrap();

    assert_eq!(ctx.consensus.get_sink(), first_sink);
    assert_eq!(ctx.consensus.get_virtual_parents(), first_parents);
    assert_eq!(ctx.consensus.get_block_status(genesis), first_status);
    assert_eq!(ctx.consensus.get_block_status(genesis), Some(BlockStatus::StatusUTXOValid));
}
'@
    [IO.File]::AppendAllText((Resolve-Path $testsPath),$test,(New-Object System.Text.UTF8Encoding($false)))
}

Write-Host 'Formatting final recovery-gap candidate...'
& rustfmt --edition 2024 --config skip_children=true protocol/flows/src/ibd/flow.rs consensus/src/pipeline/virtual_processor/tests.rs
if ($LASTEXITCODE -ne 0) { throw 'rustfmt failed' }

Write-Host 'Running final focused certification...'
& cargo check -p keryx-consensus --all-targets
if ($LASTEXITCODE -ne 0) { throw 'consensus check failed' }
& cargo check -p keryx-p2p-flows --all-targets
if ($LASTEXITCODE -ne 0) { throw 'flows check failed' }
& cargo check -p keryxd --all-targets
if ($LASTEXITCODE -ne 0) { throw 'keryxd check failed' }
& cargo clippy -p keryx-p2p-flows --all-targets --no-deps -- -D warnings -A clippy::collapsible_if
if ($LASTEXITCODE -ne 0) { throw 'flows clippy failed' }
& cargo test -p keryx-consensus pruning_point_utxo_import_replay_is_idempotent
if ($LASTEXITCODE -ne 0) { throw 'double UTXO import test failed' }
& cargo test -p keryx-p2p-flows ibd_v2::utxo_recovery
if ($LASTEXITCODE -ne 0) { throw 'UTXO recovery tests failed' }
& cargo test -p keryx-p2p-flows ibd_v2::service_state_recovery
if ($LASTEXITCODE -ne 0) { throw 'Service State regression tests failed' }

Write-Host 'Committing only the certified functional changes...'
& git add protocol/flows/src/ibd/flow.rs consensus/src/pipeline/virtual_processor/tests.rs scripts/ibd-v2/phase3/START-UTXO-CRASH-TEST.ps1
& git commit -m 'test(ibd-v2): close final UTXO recovery windows'
if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
$sha = (& git rev-parse HEAD).Trim()
Write-Host "Certified final-gap commit: $sha"
& git push origin HEAD:ibd-v2-phase3-persistent-state
if ($LASTEXITCODE -ne 0) { throw 'git push failed' }
