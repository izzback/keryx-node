$ErrorActionPreference = 'Stop'

$base155 = 'bb408d54ca3992f7f9f4e269507f7603c234d24d'
$ibdPhase3 = '7be5d296527eceff8b3e550f9afa0bd63276e492'
$upstream156 = 'a8e23793363c509325881f6146176f39bf52f77f'
$targetBranch = 'ibd-v2-integrate-v1.5.6'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

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

    # The certified Phase 3 versions of the two conflicting files already contain
    # the large IBD recovery changes. Keep those as the starting point and replay
    # only the much smaller official v1.5.5 -> v1.5.6 delta on top.
    foreach ($path in $conflicts) {
        Write-Host "Replaying official v1.5.6 delta on certified IBD file: $path"
        git checkout --ours -- $path
        if ($LASTEXITCODE -ne 0) { throw "failed to select certified IBD side for $path" }
        git add -- $path

        $safe = ($path -replace '[^A-Za-z0-9_.-]', '_')
        $patch = Join-Path $env:RUNNER_TEMP "v156-$safe.patch"
        $patchLines = @(git diff --binary $base155 $upstream156 -- $path)
        [IO.File]::WriteAllLines($patch, $patchLines, $utf8NoBom)
        if ((Get-Item $patch).Length -gt 0) {
            git apply --3way --index $patch
            if ($LASTEXITCODE -ne 0) {
                Write-Host "V156_PATCH_FAILED_BEGIN $path"
                Get-Content -LiteralPath $patch | Select-Object -First 240 | ForEach-Object { Write-Host $_ }
                Write-Host "V156_PATCH_FAILED_END $path"
                throw "official v1.5.6 delta did not apply cleanly to $path"
            }
        }
    }
}

$remaining = @(git diff --name-only --diff-filter=U)
if ($remaining.Count -gt 0) {
    Write-Host 'UNRESOLVED_CONFLICTS_BEGIN'
    foreach ($path in $remaining) { Write-Host " - $path" }
    Write-Host 'UNRESOLVED_CONFLICTS_END'
    throw "v1.5.6 integration still has $($remaining.Count) unresolved file(s)"
}

# Compatibility guards. The proto schema uses camelCase field names.
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
if ($proto -notmatch 'pom_proof_deduped') {
    throw 'official v1.5.6 compact PoM wire field was lost during integration'
}
$flow = Get-Content -Raw 'protocol/flows/src/ibd/flow.rs'
if ($flow -notmatch 'ServiceStateRecovery' -or $flow -notmatch 'UtxoRecovery' -or $flow -notmatch 'IbdStageTracker') {
    throw 'IBD v2 recovery/stage tracking hooks were lost during v1.5.6 integration'
}

$tests = Get-Content -Raw 'consensus/src/pipeline/virtual_processor/tests.rs'
if ($tests -notmatch 'pruning_point_utxo_import_replay_is_idempotent') {
    throw 'IBD v2 UTXO replay regression test was lost during v1.5.6 integration'
}

# Update only the active development reference; RUN A remains the historical
# v1.5.5 comparison baseline until a new canonical baseline is frozen.
$roadmapPath = 'docs/ibd-v2/ROADMAP.md'
if (Test-Path $roadmapPath) {
    $roadmap = Get-Content -Raw $roadmapPath
    $roadmap = $roadmap.Replace(
        'Active frozen comparison base: Keryx v1.5.5, commit `bb408d54ca3992f7f9f4e269507f7603c234d24d`.',
        'Active upstream development base: Keryx v1.5.6, commit `a8e23793363c509325881f6146176f39bf52f77f`. Canonical performance comparison remains RUN A v1.5.5 until a new baseline is explicitly frozen.'
    )
    [IO.File]::WriteAllText((Resolve-Path $roadmapPath), $roadmap, $utf8NoBom)
    git add -- $roadmapPath
}

git add -A
if ($LASTEXITCODE -ne 0) { throw 'git add failed' }

$unmerged = @(git diff --cached --name-only --diff-filter=U)
if ($unmerged.Count -gt 0) { throw "unmerged files remain: $($unmerged -join ', ')" }

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
