$ErrorActionPreference = 'Stop'

$base155 = 'bb408d54ca3992f7f9f4e269507f7603c234d24d'
$ibdPhase3 = '7be5d296527eceff8b3e550f9afa0bd63276e492'
$upstream156 = 'a8e23793363c509325881f6146176f39bf52f77f'
$targetBranch = 'ibd-v2-integrate-v1.5.6'

Write-Host "IBD v2 source: $ibdPhase3"
Write-Host "Official v1.5.6: $upstream156"

# The exact official v1.5.6 object is already pinned in this fork by
# ibd-v2-base-v1.5.6. Fetch both refs explicitly so this job never depends on
# the fork master being synchronized.
git fetch origin ibd-v2-base-v1.5.6 $targetBranch --no-tags
if ($LASTEXITCODE -ne 0) { throw 'git fetch failed' }

git config user.name 'Keryx IBD V2 Local Runner'
git config user.email 'actions@localhost'

# Start with the real merge. Non-overlapping upstream changes are accepted
# normally. We intentionally do not force a conflict strategy globally.
git merge --no-commit --no-ff origin/ibd-v2-base-v1.5.6
$mergeExit = $LASTEXITCODE

if ($mergeExit -ne 0) {
    $conflicts = @(git diff --name-only --diff-filter=U)
    Write-Host "Initial merge conflicts ($($conflicts.Count)):"
    $conflicts | ForEach-Object { Write-Host " - $_" }

    # Re-resolve each conflict from the exact official v1.5.6 version, then
    # replay only our v1.5.5->Phase3 delta as a three-way patch. This preserves
    # upstream as the primary implementation and reintroduces IBD hooks only.
    foreach ($path in $conflicts) {
        Write-Host "Three-way resolving $path"
        git checkout --theirs -- $path
        if ($LASTEXITCODE -ne 0) { throw "failed to select upstream side for $path" }
        git add -- $path

        $safe = ($path -replace '[^A-Za-z0-9_.-]', '_')
        $patch = Join-Path $env:RUNNER_TEMP "ibd-v2-$safe.patch"
        $patchLines = @(git diff --binary $base155 $ibdPhase3 -- $path)
        [IO.File]::WriteAllLines($patch, $patchLines, (New-Object System.Text.UTF8Encoding($false)))
        if ((Get-Item $patch).Length -gt 0) {
            git apply --3way --index $patch
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Automatic three-way replay still conflicts in $path"
            }
        }
    }
}

$remaining = @(git diff --name-only --diff-filter=U)
if ($remaining.Count -gt 0) {
    Write-Host 'UNRESOLVED_CONFLICTS_BEGIN'
    foreach ($path in $remaining) {
        Write-Host "===== $path ====="
        # Emit only conflict neighborhoods to keep logs readable.
        $lines = Get-Content -LiteralPath $path
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^(<<<<<<<|=======|>>>>>>>)') {
                $from = [Math]::Max(0, $i - 20)
                $to = [Math]::Min($lines.Count - 1, $i + 40)
                for ($j = $from; $j -le $to; $j++) {
                    Write-Host ('{0,6}: {1}' -f ($j + 1), $lines[$j])
                }
            }
        }
    }
    Write-Host 'UNRESOLVED_CONFLICTS_END'
    throw "v1.5.6 integration still has $($remaining.Count) unresolved file(s)"
}

# Guard the two small compatibility hooks that must survive the merge.
$pom = Get-Content -Raw 'consensus/core/src/pom_v4.rs'
if ($pom -notmatch '#\[target_feature\(enable = "neon"\)\]\s*unsafe fn half') {
    throw 'IBD v2 AArch64/NEON compatibility hook was lost during v1.5.6 integration'
}
$ctx = Get-Content -Raw 'protocol/flows/src/flow_context.rs'
if ($ctx -notmatch 'ibd_v2_state_dir') {
    throw 'IBD v2 durable state directory hook was lost during v1.5.6 integration'
}
$proto = Get-Content -Raw 'protocol/p2p/proto/p2p.proto'
if ($proto -notmatch 'previous_row_fingerprint' -or $proto -notmatch 'start_cursor') {
    throw 'IBD v2 resumable Service State wire fields were lost during v1.5.6 integration'
}
$flow = Get-Content -Raw 'protocol/flows/src/ibd/flow.rs'
if ($flow -notmatch 'ServiceStateRecovery' -or $flow -notmatch 'UtxoRecovery' -or $flow -notmatch 'IbdStageTracker') {
    throw 'IBD v2 recovery/stage tracking hooks were lost during v1.5.6 integration'
}

# Update the active upstream development reference without rewriting the
# historical RUN A v1.5.5 baseline report.
$roadmapPath = 'docs/ibd-v2/ROADMAP.md'
if (Test-Path $roadmapPath) {
    $roadmap = Get-Content -Raw $roadmapPath
    $roadmap = $roadmap.Replace(
        'Active frozen comparison base: Keryx v1.5.5, commit `bb408d54ca3992f7f9f4e269507f7603c234d24d`.',
        'Active upstream development base: Keryx v1.5.6, commit `a8e23793363c509325881f6146176f39bf52f77f`. Canonical performance comparison remains RUN A v1.5.5 until a new baseline is explicitly frozen.'
    )
    [IO.File]::WriteAllText((Resolve-Path $roadmapPath), $roadmap, (New-Object System.Text.UTF8Encoding($false)))
    git add -- $roadmapPath
}

# Ensure the merge commit includes all automatically resolved files.
git add -A
if ($LASTEXITCODE -ne 0) { throw 'git add failed' }

$unmerged = @(git diff --cached --name-only --diff-filter=U)
if ($unmerged.Count -gt 0) { throw "unmerged files remain: $($unmerged -join ', ')" }

# The caller workflow installs the pinned native toolchain before this point.
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

# Finish the pending merge created by --no-commit.
git commit -m 'chore(ibd-v2): integrate official Keryx v1.5.6'
if ($LASTEXITCODE -ne 0) { throw 'merge commit failed' }

$sha = (git rev-parse HEAD).Trim()
Write-Host "Integrated v1.5.6 HEAD: $sha"
git push origin HEAD:$targetBranch
if ($LASTEXITCODE -ne 0) { throw 'push failed' }

$exe = Join-Path $PWD 'target\release\keryxd.exe'
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash.ToLowerInvariant()
Write-Host "keryxd.exe SHA256=$hash"
