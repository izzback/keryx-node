$ErrorActionPreference = 'Stop'

$base = '5cf2a494c1a54348f51fb560928fe473fdef08a4'
$branch = 'ibd-v2-phase4-db-batching'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-Text([string]$Path) {
    return [IO.File]::ReadAllText((Resolve-Path $Path))
}

function Write-Text([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText((Resolve-Path $Path), $Text, $utf8NoBom)
}

function Replace-Once([string]$Path, [string]$Old, [string]$New) {
    $text = Read-Text $Path
    $first = $text.IndexOf($Old, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "anchor not found in ${Path}: $($Old.Substring(0, [Math]::Min(80, $Old.Length)))" }
    $second = $text.IndexOf($Old, $first + $Old.Length, [StringComparison]::Ordinal)
    if ($second -ge 0) { throw "anchor is not unique in $Path" }
    Write-Text $Path ($text.Substring(0, $first) + $New + $text.Substring($first + $Old.Length))
}

function Replace-Before([string]$Path, [string]$Start, [string]$End, [string]$Replacement) {
    $text = Read-Text $Path
    $s = $text.IndexOf($Start, [StringComparison]::Ordinal)
    if ($s -lt 0) { throw "start anchor not found in $Path" }
    $e = $text.IndexOf($End, $s + $Start.Length, [StringComparison]::Ordinal)
    if ($e -lt 0) { throw "end anchor not found in $Path" }
    Write-Text $Path ($text.Substring(0, $s) + $Replacement + $text.Substring($e))
}

$ancestor = (git merge-base $base HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $ancestor -ne $base) {
    throw "Phase 4 branch is not based on certified v1.5.6 integration $base"
}

# 1. Consensus API: expose a bounded, cursor-based missing-body scan.
$path = 'consensus/core/src/api/mod.rs'
$old = @'
    fn get_missing_block_body_hashes(&self, high: Hash) -> ConsensusResult<Vec<Hash>> {
        unimplemented!()
    }
'@
$new = @'
    fn get_missing_block_body_hashes(&self, high: Hash) -> ConsensusResult<Vec<Hash>> {
        unimplemented!()
    }

    /// Returns at most one bounded traversal window of body-missing hashes between an optional
    /// chain cursor and `high`. `next_cursor` is consensus-derived and advances even when every
    /// block in the traversed window already has a body; `done` means the scan reached `high`.
    fn get_missing_block_body_hashes_batch(
        &self,
        low: Option<Hash>,
        high: Hash,
        max_blocks: usize,
    ) -> ConsensusResult<(Vec<Hash>, Hash, bool)> {
        unimplemented!()
    }
'@
Replace-Once $path $old $new

# 2. SyncManager: perform traversal and status filtering under one consensus call.
$path = 'consensus/src/processes/sync/mod.rs'
$marker = '    pub fn create_block_locator_from_pruning_point('
$addition = @'
    /// Bounded/cursor-based variant used by IBD v2 Phase 4. The first call (`low == None`)
    /// locates the highest chain block whose body is already durable. Continuations pass the
    /// previous `highest_reached`, avoiding a full pruning-point-to-tip rescan for every batch.
    ///
    /// The cursor follows chain progress, not the filtered result. This is important because a
    /// traversal window may contain zero header-only blocks and must still make forward progress.
    pub fn get_missing_block_body_hashes_batch(
        &self,
        low: Option<Hash>,
        high: Hash,
        max_blocks: usize,
    ) -> SyncManagerResult<(Vec<Hash>, Hash, bool)> {
        let pp = self.pruning_point_store.read().pruning_point().unwrap();
        if !self.reachability_service.is_chain_ancestor_of(pp, high) {
            return Err(SyncManagerError::PruningPointNotInChain(pp, high));
        }

        let low = if let Some(low) = low {
            if !self.reachability_service.is_chain_ancestor_of(pp, low)
                || !self.reachability_service.is_chain_ancestor_of(low, high)
            {
                return Err(SyncManagerError::LocatorLowHashNotInHighHashChain(low, high));
            }
            low
        } else {
            let mut highest_with_body = None;
            let mut forward_iterator = self.reachability_service.forward_chain_iterator(pp, high, true).tuple_windows();
            let mut backward_iterator = self.reachability_service.backward_chain_iterator(high, pp, true);
            loop {
                let Some((parent, current)) = forward_iterator.next() else {
                    break;
                };
                if self.statuses_store.read().get(current).unwrap().is_header_only() {
                    highest_with_body = Some(parent);
                    break;
                }

                let Some(backward_current) = backward_iterator.next() else {
                    break;
                };
                if self.statuses_store.read().get(backward_current).unwrap().has_block_body() {
                    highest_with_body = Some(backward_current);
                    break;
                }
            }

            let Some(low) = highest_with_body else {
                return Ok((vec![], high, true));
            };
            if low == high {
                return Ok((vec![], high, true));
            }
            low
        };

        if low == high {
            return Ok((vec![], high, true));
        }

        // `antipast_hashes_between` works with mergeset granularity, so a window must be at least
        // the configured mergeset limit in order to guarantee cursor progress.
        let max_blocks = max_blocks.max(self.mergeset_size_limit as usize);
        let (mut hashes, highest_reached) = self.antipast_hashes_between(low, high, Some(max_blocks));
        debug_assert_ne!(highest_reached, low, "bounded missing-body scan must advance its chain cursor");

        let statuses = self.statuses_store.read();
        hashes.retain(|&hash| statuses.get(hash).unwrap().is_header_only());
        let done = highest_reached == high;
        Ok((hashes, highest_reached, done))
    }

'@
$text = Read-Text $path
if ($text.Contains('pub fn get_missing_block_body_hashes_batch(')) { throw 'Phase 4 SyncManager batch API already exists' }
$idx = $text.IndexOf($marker, [StringComparison]::Ordinal)
if ($idx -lt 0) { throw 'SyncManager insertion marker not found' }
Write-Text $path ($text.Substring(0, $idx) + $addition + $text.Substring($idx))

# 3. Consensus implementation: retain the pruning lock and validate both cursor and target.
$path = 'consensus/src/consensus/mod.rs'
$old = @'
    fn get_missing_block_body_hashes(&self, high: Hash) -> ConsensusResult<Vec<Hash>> {
        let _guard = self.pruning_lock.blocking_read();
        self.validate_block_exists(high)?;
        Ok(self.services.sync_manager.get_missing_block_body_hashes(high)?)
    }
'@
$new = @'
    fn get_missing_block_body_hashes(&self, high: Hash) -> ConsensusResult<Vec<Hash>> {
        let _guard = self.pruning_lock.blocking_read();
        self.validate_block_exists(high)?;
        Ok(self.services.sync_manager.get_missing_block_body_hashes(high)?)
    }

    fn get_missing_block_body_hashes_batch(
        &self,
        low: Option<Hash>,
        high: Hash,
        max_blocks: usize,
    ) -> ConsensusResult<(Vec<Hash>, Hash, bool)> {
        let _guard = self.pruning_lock.blocking_read();
        self.validate_block_exists(high)?;
        if let Some(low) = low {
            self.validate_block_exists(low)?;
        }
        Ok(self.services.sync_manager.get_missing_block_body_hashes_batch(low, high, max_blocks)?)
    }
'@
Replace-Once $path $old $new

# 4. Async proxy wrapper.
$path = 'components/consensusmanager/src/session.rs'
$old = @'
    pub async fn async_get_missing_block_body_hashes(&self, high: Hash) -> ConsensusResult<Vec<Hash>> {
        self.clone().spawn_blocking(move |c| c.get_missing_block_body_hashes(high)).await
    }
'@
$new = @'
    pub async fn async_get_missing_block_body_hashes(&self, high: Hash) -> ConsensusResult<Vec<Hash>> {
        self.clone().spawn_blocking(move |c| c.get_missing_block_body_hashes(high)).await
    }

    pub async fn async_get_missing_block_body_hashes_batch(
        &self,
        low: Option<Hash>,
        high: Hash,
        max_blocks: usize,
    ) -> ConsensusResult<(Vec<Hash>, Hash, bool)> {
        self.clone().spawn_blocking(move |c| c.get_missing_block_body_hashes_batch(low, high, max_blocks)).await
    }
'@
Replace-Once $path $old $new

# 5. IBD flow: bounded search windows while preserving validation/network pipelining across windows.
$path = 'protocol/flows/src/ibd/flow.rs'
Replace-Once $path 'type BlockBody = Vec<Transaction>;' "type BlockBody = Vec<Transaction>;`nconst IBD_BODY_SEARCH_BATCH_SIZE: usize = IBD_BATCH_SIZE * 64;"
$start = '    async fn sync_missing_block_bodies(&mut self, consensus: &ConsensusProxy, high: Hash) -> Result<(), ProtocolError> {'
$end = '    async fn queue_block_processing_chunk('
$replacement = @'
    async fn sync_missing_block_bodies(&mut self, consensus: &ConsensusProxy, high: Hash) -> Result<(), ProtocolError> {
        let high_header = consensus.async_get_header(high).await?;
        let high_daa = high_header.daa_score;
        let pom_stage_started = metrics_enabled().then(Instant::now);
        let mut pom_totals = PomChunkMetrics::default();
        let mut validation_blocked = Duration::ZERO;
        let mut progress_reporter: Option<ProgressReporter> = None;
        let mut previous: Option<QueueChunkOutput> = None;
        let mut cursor: Option<Hash> = None;
        let mut done = false;
        let mut first_search = true;
        let mut search_windows = 0u64;
        let mut returned_hashes = 0u64;

        while !done {
            let search = consensus.async_get_missing_block_body_hashes_batch(cursor, high, IBD_BODY_SEARCH_BATCH_SIZE);
            tokio::pin!(search);
            let (hashes, next_cursor, batch_done) = if first_search {
                let sleep_task = sleep(Duration::from_secs(2));
                tokio::pin!(sleep_task);
                match select(sleep_task, search).await {
                    Either::Left((_, search)) => {
                        info!(
                            "IBD: searching for the first bounded missing-body window from peer {}. This operation might take several seconds.",
                            self.router
                        );
                        search.await?
                    }
                    Either::Right((result, _)) => result?,
                }
            } else {
                search.await?
            };
            first_search = false;
            search_windows = search_windows.saturating_add(1);
            returned_hashes = returned_hashes.saturating_add(hashes.len() as u64);

            if cursor == Some(next_cursor) && !batch_done {
                return Err(ProtocolError::Other("bounded missing-body consensus scan did not advance its cursor"));
            }
            cursor = Some(next_cursor);
            done = batch_done;

            if hashes.is_empty() {
                continue;
            }

            if progress_reporter.is_none() {
                let low_header = consensus.async_get_header(hashes[0]).await?;
                progress_reporter = Some(ProgressReporter::new(low_header.daa_score, high_header.daa_score, "blocks"));
            }

            for chunk in hashes.chunks(IBD_BATCH_SIZE) {
                let current = self.queue_block_processing_chunk(consensus, chunk, high_daa).await?;
                pom_totals.merge(PomChunkMetrics {
                    blocks: current.pom.blocks,
                    proofs: current.pom.proofs,
                    proof_bytes: current.pom.proof_bytes,
                    reproofs_queued: current.pom.reproofs_queued,
                    discarded_historical_proofs: current.pom.discarded_historical_proofs,
                    discarded_historical_bytes: current.pom.discarded_historical_bytes,
                    decode_time: current.pom.decode_time,
                    peer_wait_time: current.pom.peer_wait_time,
                });

                if let Some(previous) = previous.replace(current) {
                    let prev_chunk_len = previous.jobs.len();
                    let validation_wait_started = metrics_enabled().then(Instant::now);
                    try_join_all(previous.jobs).await?;
                    if let Some(validation_wait_started) = validation_wait_started {
                        validation_blocked = validation_blocked.saturating_add(validation_wait_started.elapsed());
                    }
                    progress_reporter
                        .as_mut()
                        .expect("reporter exists once a missing body was queued")
                        .report(prev_chunk_len, previous.daa_score, previous.timestamp);
                }
            }
        }

        let Some(previous) = previous else {
            if metrics_enabled() {
                info!(
                    "IBD-V2-METRICS: stage=body-search complete=true search_windows={} returned_hashes=0",
                    search_windows
                );
            }
            return Ok(());
        };

        let prev_chunk_len = previous.jobs.len();
        let validation_wait_started = metrics_enabled().then(Instant::now);
        try_join_all(previous.jobs).await?;
        if let Some(validation_wait_started) = validation_wait_started {
            validation_blocked = validation_blocked.saturating_add(validation_wait_started.elapsed());
        }
        progress_reporter
            .as_mut()
            .expect("reporter exists once a missing body was queued")
            .report_completion(prev_chunk_len);

        if metrics_enabled() {
            let elapsed = pom_stage_started.expect("metrics start is present when metrics are enabled").elapsed();
            let elapsed_seconds = elapsed.as_secs_f64();
            let blocks_per_second = if elapsed_seconds == 0.0 { 0.0 } else { pom_totals.blocks as f64 / elapsed_seconds };
            let proof_megabytes_per_second =
                if elapsed_seconds == 0.0 { 0.0 } else { (pom_totals.proof_bytes as f64 / 1_000_000.0) / elapsed_seconds };
            let peer_wait_ratio =
                if elapsed_seconds == 0.0 { 0.0 } else { (pom_totals.peer_wait_time.as_secs_f64() / elapsed_seconds).clamp(0.0, 1.0) };
            info!(
                "IBD-V2-METRICS: stage=pom-body-sync mode={} complete=true search_windows={} returned_hashes={} blocks={} proofs={} proof_bytes={} proof_bytes_measured={} reproofs_queued={} discarded_historical_proofs={} discarded_historical_bytes={} elapsed={:.3}s rate={:.2} blocks/s proof_throughput={:.2} MB/s peer_wait={:.3}s peer_wait_pct={:.1}% decode={:.3}s validation_blocked={:.3}s",
                if self.body_only_ibd_permitted { "body-only" } else { "full-block" },
                search_windows,
                returned_hashes,
                pom_totals.blocks,
                pom_totals.proofs,
                pom_totals.proof_bytes,
                self.body_only_ibd_permitted,
                pom_totals.reproofs_queued,
                pom_totals.discarded_historical_proofs,
                pom_totals.discarded_historical_bytes,
                elapsed_seconds,
                blocks_per_second,
                proof_megabytes_per_second,
                pom_totals.peer_wait_time.as_secs_f64(),
                peer_wait_ratio * 100.0,
                pom_totals.decode_time.as_secs_f64(),
                validation_blocked.as_secs_f64()
            );
        }

        Ok(())
    }

'@
Replace-Before $path $start $end $replacement

$changed = @(
    'consensus/core/src/api/mod.rs',
    'consensus/src/processes/sync/mod.rs',
    'consensus/src/consensus/mod.rs',
    'components/consensusmanager/src/session.rs',
    'protocol/flows/src/ibd/flow.rs'
)

Write-Host 'Formatting Phase 4 candidate...'
foreach ($file in $changed) {
    rustfmt --edition 2024 $file
    if ($LASTEXITCODE -ne 0) { throw "rustfmt failed for $file" }
}

git diff --check
if ($LASTEXITCODE -ne 0) { throw 'git diff --check failed' }

Write-Host 'Running Phase 4 v1.5.6 checks...'
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

cargo clippy -p keryx-consensus -p keryx-consensusmanager -p keryx-p2p-flows --all-targets -- -D warnings
if ($LASTEXITCODE -ne 0) { throw 'Phase 4 Clippy failed' }

cargo test -p keryx-p2p-flows ibd_v2
if ($LASTEXITCODE -ne 0) { throw 'IBD v2 regression tests failed' }
cargo test -p keryx-consensus pruning_point_utxo_import_replay_is_idempotent
if ($LASTEXITCODE -ne 0) { throw 'UTXO replay regression failed' }

cargo build --release -p keryxd
if ($LASTEXITCODE -ne 0) { throw 'release build failed' }

# Guard the v1.5.6 PoM wire integration while Phase 4 changes body-sync control flow.
$flow = Read-Text 'protocol/flows/src/ibd/flow.rs'
foreach ($needle in @('decode_pom_proof', 'pom_proof_min_daa', 'ServiceStateRecovery', 'UtxoRecovery', 'IbdStageTracker')) {
    if (-not $flow.Contains($needle)) { throw "v1.5.6 / IBD v2 guard lost: $needle" }
}

# Only now publish the functional candidate.
git add -- $changed
git commit -m 'perf(ibd-v2): batch missing body consensus scans'
if ($LASTEXITCODE -ne 0) { throw 'functional Phase 4 commit failed' }
$sha = (git rev-parse HEAD).Trim()
Write-Host "PHASE4_HEAD=$sha"
git push origin HEAD:$branch
if ($LASTEXITCODE -ne 0) { throw 'Phase 4 push failed' }

$exe = Join-Path $PWD 'target\release\keryxd.exe'
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash.ToLowerInvariant()
Write-Host "keryxd.exe SHA256=$hash"
