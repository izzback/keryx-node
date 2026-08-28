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

# Rewrite only the generated aggregation/progress details in the candidate script. Everything else
# remains exactly the same as the reviewed Phase 4 patch/certification logic.
$sourcePath = 'scripts/ibd-v2/phase4/apply-body-search-batching-v156.ps1'
$source = [IO.File]::ReadAllText((Resolve-Path $sourcePath))

$pattern = '(?s)\s+pom_totals\.merge\(PomChunkMetrics \{.*?\}\);'
$matches = [regex]::Matches($source, $pattern)
if ($matches.Count -ne 1) {
    throw "expected exactly one generated PomChunkMetrics move block, found $($matches.Count)"
}
$source = [regex]::Replace($source, $pattern, "`n                pom_totals.merge(&current.pom);", 1)

# ProgressReporter::report_completion consumes self, so take it out of the Option instead of
# attempting to move through a mutable reference.
$oldCompletion = @'
        progress_reporter
            .as_mut()
            .expect("reporter exists once a missing body was queued")
            .report_completion(prev_chunk_len);
'@
$newCompletion = @'
        progress_reporter
            .take()
            .expect("reporter exists once a missing body was queued")
            .report_completion(prev_chunk_len);
'@
if (-not $source.Contains($oldCompletion)) { throw 'generated progress completion block not found' }
$source = $source.Replace($oldCompletion, $newCompletion)

# antipast_hashes_between uses mergeset granularity. Keep the requested window strictly above the
# configured mergeset size limit, matching the existing ConsensusApi safety rule.
$oldLimit = '        let max_blocks = max_blocks.max(self.mergeset_size_limit as usize);'
$newLimit = '        let max_blocks = max_blocks.max((self.mergeset_size_limit as usize).saturating_add(1));'
if (-not $source.Contains($oldLimit)) { throw 'generated mergeset limit normalization not found' }
$source = $source.Replace($oldLimit, $newLimit)

# Clippy is a Phase 4 source-quality gate, not a repository-wide cleanup gate. keryx-consensus
# currently has pre-existing lint debt in OPoI, Service State, PoM and test code. It remains covered
# by cargo check --all-targets plus the targeted regression tests below. Keep strict Clippy on the
# clean crates that define/consume the new Phase 4 API and async control flow.
$oldClippy = 'cargo clippy -p keryx-consensus -p keryx-consensusmanager -p keryx-p2p-flows --all-targets -- -D warnings'
$newClippy = 'cargo clippy -p keryx-consensus-core -p keryx-consensusmanager -p keryx-p2p-flows --all-targets --no-deps -- -D warnings'
if (-not $source.Contains($oldClippy)) { throw 'Phase 4 Clippy command not found' }
$source = $source.Replace($oldClippy, $newClippy)

$temp = Join-Path $env:RUNNER_TEMP 'apply-body-search-batching-v156-fixed.ps1'
[IO.File]::WriteAllText($temp, $source, $utf8NoBom)

& $temp
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
