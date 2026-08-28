$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# The Phase 4 body-sync loop keeps QueueChunkOutput alive across the validation pipeline.
# Make metric aggregation borrow the chunk metrics instead of moving them out of the queued item.
$flowPath = 'protocol/flows/src/ibd/flow.rs'
$flow = [IO.File]::ReadAllText((Resolve-Path $flowPath))
$oldMerge = '    fn merge(&mut self, other: Self) {'
$newMerge = '    fn merge(&mut self, other: &Self) {'
if ($flow.Contains($oldMerge)) {
    $flow = $flow.Replace($oldMerge, $newMerge)
    [IO.File]::WriteAllText((Resolve-Path $flowPath), $flow, $utf8NoBom)
} elseif (-not $flow.Contains($newMerge)) {
    throw 'PomChunkMetrics::merge signature not found'
}

# Rewrite only the generated aggregation block in the candidate script. Everything else remains
# exactly the same as the reviewed Phase 4 patch/certification logic.
$sourcePath = 'scripts/ibd-v2/phase4/apply-body-search-batching-v156.ps1'
$source = [IO.File]::ReadAllText((Resolve-Path $sourcePath))
$pattern = '(?s)\s+pom_totals\.merge\(PomChunkMetrics \{.*?\}\);'
$matches = [regex]::Matches($source, $pattern)
if ($matches.Count -ne 1) {
    throw "expected exactly one generated PomChunkMetrics move block, found $($matches.Count)"
}
$source = [regex]::Replace($source, $pattern, "`n                pom_totals.merge(&current.pom);", 1)
$temp = Join-Path $env:RUNNER_TEMP 'apply-body-search-batching-v156-fixed.ps1'
[IO.File]::WriteAllText($temp, $source, $utf8NoBom)

& $temp
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
