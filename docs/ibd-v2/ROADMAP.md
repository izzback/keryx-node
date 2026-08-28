# Keryx IBD v2 Roadmap

Updated: 2026-08-28

## Fixed baseline

- Official frozen base: Keryx v1.5.5
- Official base commit: `bb408d54ca3992f7f9f4e269507f7603c234d24d`
- Immutable base branch: `ibd-v2-base-v1.5.5`
- Validated integration branch: `ibd-v2-integrate-v1.5.5`
- Active Phase 3 branch: `ibd-v2-phase3-persistent-state`
- Canonical RUN A baseline: 95.17 minutes on the baseline host
- IBD v2 remains disabled by default and opt-in with `KERYX_IBD_V2=1`
- Certification policy: local runner only, `[self-hosted, Windows, X64]`

## Phase 0 — Reproducible baseline — COMPLETE

- [x] Freeze official v1.5.5 source baseline.
- [x] Integrate IBD v2 history without modifying immutable reference branches.
- [x] Validate upstream-sensitive PoM, SIMD, AArch64/NEON, storage, database and keryxd compatibility.
- [x] Produce and validate canonical Windows RUN A collector.
- [x] Run a clean default-parameter mainnet baseline.
- [x] Freeze baseline report and metrics.
- [x] Identify peer wait as the dominant PoM/body-sync performance bottleneck.

No performance tuning is allowed to redefine this baseline.

## Phase 3 — Persistent IBD state and crash recovery — ACTIVE / ADVANCED

### 3A. Durable checkpoint foundation — COMPLETE / CI CERTIFIED

- [x] Versioned checkpoint format with magic/version/length/checksum.
- [x] Atomic checkpoint replacement.
- [x] Network/genesis binding.
- [x] Pruning-point binding.
- [x] Independent stage states: Headers, Pruning, UTXO, Service State, PoM, Bodies.
- [x] Checkpoint progress can never be trusted as consensus/database truth by itself.
- [x] Reject truncated checkpoints.
- [x] Reject corrupted/checksum-invalid checkpoints.
- [x] Reject unsupported versions.
- [x] Reject checkpoints from another genesis/network.
- [x] Reject stale pruning-point checkpoints.
- [x] Reject semantically invalid stage sets/progress.
- [x] Reject short/truncated headers.

### 3B. Service State durable recovery — IMPLEMENTED / CI CERTIFIED / LIVE TEST PENDING

- [x] Durable Service State spool.
- [x] Fsync-before-checkpoint ordering.
- [x] Cursor + previous-row fingerprint resume anchor.
- [x] Recovery reconciles a lagging checkpoint from durable spool data.
- [x] Verified state replays locally without network redownload.
- [x] Service State import uses atomic RocksDB batch semantics.
- [x] Committed state is not replayed unnecessarily.
- [x] Deterministic fault points:
  - `service-state-after-spool-fsync`
  - `service-state-after-checkpoint`
  - `service-state-after-verified`
  - `service-state-after-import`
- [ ] Execute the real mainnet crash/restart matrix and archive evidence.

### 3C. UTXO durable recovery — IMPLEMENTED / CI CERTIFIED / LIVE TEST PENDING

- [x] Persist UTXO lifecycle: NotStarted -> Downloading -> Verified -> Committed.
- [x] Preserve durable partial pruning UTXO RocksDB state after crash.
- [x] Reconstruct durable UTXO count and MuHash from RocksDB on restart.
- [x] Reconcile checkpoint progress from RocksDB instead of trusting metadata ahead of storage.
- [x] Resume peers that cannot seek by draining the resent prefix to the exact durable anchor.
- [x] Validate anchor value before accepting the remaining suffix.
- [x] Final commitment still cryptographically verifies the reconstructed prefix + new suffix.
- [x] Verified UTXO state can replay final import locally without downloading the snapshot again.
- [x] Final pruning-point import is covered by a double-import idempotence regression test.
- [x] Service State is armed before UTXO stability is exposed.
- [x] Deterministic fault points:
  - `utxo-after-clear`
  - `utxo-after-checkpoint`
  - `utxo-after-chunk-commit`
  - `utxo-after-verified`
  - `utxo-after-import`
  - `utxo-after-committed`
- [ ] Execute the real mainnet crash/restart matrix and archive evidence.

### 3D. Final certified real-test package — COMPLETE

Permanent local Windows gate: `33182774771` — GREEN.

Certified package head:

`5bb59c04a0fb7c62d870475220822c88a08c93e8`

Functional UTXO final-gap commit contained by that head:

`d921b29d108cf5d3cb7d4f53addbe81fd0502345`

Artifact:

`keryx-ibd-v2-phase3-realtest-5bb59c04a0fb7c62d870475220822c88a08c93e8`

Artifact ZIP SHA-256:

`e1533479c26f62228fb9bc4fd156f47c412be5909db109fc3ad1628c86e13a7b`

`keryxd.exe` SHA-256:

`2e17fb843758b65aea6df53edffa779c8ac57e1e8861903315f59077d7fbd752`

The ZIP digest was independently matched against the GitHub artifact digest and the executable digest was independently matched against the internal build manifest.

### 3E. PoM and block-body durable recovery boundaries — NEXT OFFLINE DEVELOPMENT PRIORITY

Current state: the checkpoint schema already contains independent `Pom` and `Bodies` stages, and the legacy IBD path already reconstructs missing bodies from consensus. However, Phase 3 does not yet provide the same explicit durable recovery coordinator and crash-boundary certification for PoM/body progress as it now does for UTXO and Service State.

Required work before Phase 3 can be declared complete:

- [ ] Define the minimal durable PoM/body checkpoint semantics.
- [ ] Never checkpoint a PoM/body unit before the corresponding consensus/database state is durable.
- [ ] Persist a safe body-sync target only when it can be reconstructed from local consensus after restart.
- [ ] Recompute remaining missing bodies from consensus rather than trusting a persisted list.
- [ ] Define whether PoM progress needs a separate durable cursor or can be derived entirely from durable block/proof state.
- [ ] Add deterministic hard-crash fault points around the selected durable boundaries.
- [ ] Add unit/integration tests proving restart never skips non-durable body/proof work.
- [ ] Add those tests to the permanent local Windows Phase 3 gate.

### 3F. Real Phase 3 crash/restart campaign — BLOCKED ONLY BY NODE AVAILABILITY

When the test nodes can run again:

1. Stop every unrelated `keryxd` process.
2. Use only dedicated Phase 3 datadirs; never touch the historical node datadir.
3. Execute Service State crash points.
4. Execute UTXO crash points.
5. Reuse a cold-cloned Verified UTXO state for `utxo-after-import` and `utxo-after-committed` so the large UTXO set does not need to be downloaded repeatedly.
6. Execute PoM/body crash points after 3E is implemented.
7. Archive logs, checkpoint state, hashes, restart behavior and final sync outcome for every test.
8. Phase 3 is GREEN only if every crash resumes without silent data loss, invalid trust advancement, ambiguous final state, or unnecessary full restart.

## Phase 1 — Scheduler and adaptive budgets — LOCKED UNTIL PHASE 3 GREEN

After Phase 3:

- [ ] Stage-aware scheduler.
- [ ] Adaptive in-flight work budgets.
- [ ] Backpressure based on validation/storage pressure.
- [ ] Preserve bounded memory use.
- [ ] Keep consensus verification unchanged.
- [ ] Measure CPU, RAM, disk, network and peer-wait utilization.

No multi-peer racing yet unless separately reviewed.

## Phase 2 — Throughput and download improvements — LOCKED UNTIL PHASE 1 SAFE

- [ ] Reduce PoM/body peer-wait time identified by RUN A.
- [ ] Pipeline network receipt and local validation more aggressively where safe.
- [ ] Improve batching without moving durability boundaries ahead of storage.
- [ ] Evaluate peer capability discovery.
- [ ] Only then evaluate multi-peer/chunk scheduling.
- [ ] HTTP mirrors/alternate transports remain optional future transports and never trust anchors.

## Final comparative benchmark

Repeat the canonical RUN A methodology with IBD v2 enabled:

- Fresh empty datadir.
- Default comparable node settings.
- Same host and measurement methodology where practical.
- 5-second resource sampling.
- Stage metrics enabled.
- Record total sync time, phase durations, CPU/RAM/disk/network use, peer wait, throughput, stalls and restart overhead.
- Compare against frozen RUN A = 95.17 minutes.

## Release gates

IBD v2 must remain opt-in until all of the following are GREEN:

- [ ] Phase 3 real crash/restart evidence.
- [ ] PoM/body durable recovery boundaries.
- [ ] Scheduler safety.
- [ ] Throughput implementation correctness.
- [ ] Comparative benchmark.
- [ ] Upstream compatibility gate after final rebase/update.
- [ ] No consensus validity or serialization divergence.

## Non-negotiable architecture rule

The remote source is never trusted. Every peer, future mirror or alternate transport only supplies bytes. Keryx locally verifies cryptographic commitments, consensus rules and durable state before committing progress.
