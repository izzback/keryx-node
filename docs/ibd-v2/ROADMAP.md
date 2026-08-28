# Keryx IBD v2 Roadmap

Updated: 2026-08-28

> This document follows the canonical project order. The Phase 3 implementation was completed on the historical branch `ibd-v2-phase3-persistent-state`; active development now proceeds to Phase 4 without redefining roadmap numbering.

## Status legend

â¬œ Planned
ðŸŸ¨ In progress
ðŸ§ª In testing
âœ… Validated
â›” Blocked

---

# Objective

Improve Keryx Initial Block Download so that a new node can synchronize:

- faster
- with lower RAM pressure
- with fewer unnecessary database reads
- without restarting large downloads after disconnection
- without depending on a trusted central server
- without requiring inbound ports
- while preserving full local verification

Fundamental principle:

Transport may come from anyone.
Validation must always remain local.

Active upstream development base: Keryx v1.5.6, commit `a8e23793363c509325881f6146176f39bf52f77f`. Canonical performance comparison remains RUN A v1.5.5 until a new baseline is explicitly frozen.
Canonical RUN A baseline: **95.17 minutes**.

---

# Phase 0 â€” IBD instrumentation

Overall status: ðŸŸ¨ Very advanced

âœ… Add detailed metrics for the main IBD stages
âœ… Measure header download throughput
âœ… Measure body download throughput
âœ… Measure PoM proof throughput
âœ… Measure UTXO download throughput
âœ… Measure Service State throughput
âœ… Measure network bandwidth usage
ðŸŸ¨ Measure validation CPU time with sufficiently fine granularity
â¬œ Measure direct RocksDB read/write latency per IBD operation
âœ… Measure peer wait / idle time
âœ… Measure time spent in the main IBD stages

Target metrics:

- headers/sec
- blocks/sec
- PoM proofs/sec
- UTXOs/sec
- Service State rows/sec
- MB/sec
- validation CPU time per block
- RocksDB latency
- peer idle time
- total IBD duration

Important RUN A result: PoM/body sync is heavily constrained by peer wait.

Objective:

Identify the real bottlenecks before modifying protocol behavior.

No consensus modification.

---

# Phase 1 â€” Resumable Service State synchronization

Overall status: ðŸ§ª Implemented and CI-certified, real mainnet testing pending

âœ… Add chunk identifiers / cursors
âœ… Add durable temporary Service State storage
âœ… Persist download progress
âœ… Persist the current cursor
âœ… Persist verification progress (`DOWNLOADING` / `VERIFIED` / `COMMITTED`)
ðŸ§ª Resume after node crash
ðŸ§ª Resume after node update
ðŸ§ª Resume after peer disconnect
ðŸ§ª Resume from another peer
âœ… Verify the final Service State commitment
âœ… Atomically commit verified state through RocksDB WriteBatch

Already certified implementation:

- durable spool
- fsync before checkpoint advancement
- cursor + previous-row fingerprint
- local replay from `VERIFIED`
- no network redownload needed for `VERIFIED` replay
- fault points:
  - `service-state-after-spool-fsync`
  - `service-state-after-checkpoint`
  - `service-state-after-verified`
  - `service-state-after-import`

Still requiring mainnet validation: real crash/restart matrix, peer change and network-disconnect recovery.

Objective:

Never restart a large Service State download from zero unless the pruning point itself becomes invalid.

No change to consensus validity rules.

---

# Phase 2 â€” Resumable UTXO state synchronization

Overall status: ðŸ§ª Implemented and CI-certified, real mainnet testing pending

ðŸŸ¨ Add deterministic cursors for UTXO chunks

Compatibility note: the first implementation uses a deterministic anchor on the last durable outpoint because current v1.5.5 peers cannot seek directly into the UTXO stream. A non-seeking peer resends the prefix, which is verified/drained to the durable anchor. A true network cursor can be added later without losing backward compatibility.

âœ… Use temporary/durable UTXO storage

Implementation note: the existing pruning UTXO RocksDB is reused instead of creating a redundant second database.

âœ… Persist completed chunks with an atomic WriteBatch per chunk
âœ… Persist progress metadata
ðŸ§ª Resume after restart
ðŸ§ª Resume after network interruption
ðŸ§ª Resume from another peer
âœ… Verify the complete UTXO commitment by reconstructing MuHash
ðŸ§ª Transition to verified/committed UTXO state with safe recovery around the boundary

Already certified implementation:

- reconstruct durable prefix from RocksDB
- reconstruct MuHash after restart
- skip already durable network prefix
- append only missing suffix
- local replay after `VERIFIED`
- final double import tested as idempotent
- fault points:
  - `utxo-after-clear`
  - `utxo-after-checkpoint`
  - `utxo-after-chunk-commit`
  - `utxo-after-verified`
  - `utxo-after-import`
  - `utxo-after-committed`

Objective:

Avoid unnecessarily redownloading multiple gigabytes of state.

---

# Phase 3 â€” Independent IBD stage tracking

Overall status: ðŸ§ª Implemented and CI-certified, real mainnet testing pending

âœ… Track Headers independently
âœ… Track Pruning independently
âœ… Track UTXO independently
âœ… Track Service State independently
âœ… Track PoM independently at the Phase 3 lifecycle level (`DOWNLOADING` â†’ `VERIFIED`)
âœ… Track Bodies independently

Implemented checkpoint states:

NOT_STARTED
DOWNLOADING
VERIFIED
COMMITTED

The durable checkpoint format is:

- versioned
- protected by a cryptographic checksum
- bound to network/genesis
- bound to pruning point
- atomically replaced
- able to reject corruption, truncation, unsupported versions and stale checkpoints

Certified Phase 3 implementation:

- `IbdStageTracker` persists independent lifecycle state in the shared durable checkpoint
- every tracker mutation reloads the latest checkpoint before writing, preventing stale writers from overwriting newer UTXO or Service State progress
- Headers enter `DOWNLOADING` before sync and reach `COMMITTED` only after successful work
- headers-proof Pruning/Headers are reconciled as `COMMITTED` only after the real staging consensus `commit()`
- Pruning catch-up is reconciled from durable local consensus facts
- Bodies persist a reconstructible body-sync target, but never trust a persisted missing-body list as consensus truth
- Bodies reach `VERIFIED` then `COMMITTED` after successful body processing
- PoM is tracked independently through `DOWNLOADING` and `VERIFIED`; independent PoM proof persistence/provider recovery and the PoM `COMMITTED` transition remain Phase 5 work
- stale pruning-point checkpoints reset stage tracking safely

Certification:

- functional commit: `dca15c25cef891cdb610da054167936b91ce6a21`
- clean Phase 3 head: `c21b7c1a10917f15116ee99cfeebb8d541ff5f6d`
- permanent local-runner gate: `33192674907`
- format, P2P wire, consensus, P2P flows, keryxd, Clippy, recovery tests, release build, package and artifact upload all passed

Remaining Phase 3 validation belongs to the real crash/restart and mainnet campaign in Phase 11; it does not block starting the next offline implementation phase.

Objective:

Make IBD recoverable instead of treating synchronization as one large all-or-nothing operation.

---

# Phase 4 â€” Database batching and validation

Overall status: ðŸŸ¨ Active development phase

â¬œ Batch header lookups
â¬œ Batch block-status lookups
ðŸŸ¨ Batch missing-body queries
â¬œ Use RocksDB `multi_get` where appropriate
â¬œ Reduce repeated async consensus calls
â¬œ Pipeline network download and validation
â¬œ Pipeline validation and database writes
â¬œ Dynamically adjust IBD batch sizes
â¬œ Add queue backpressure

First audited target:

- current `sync_missing_block_bodies` calls `async_get_missing_block_body_hashes(high)`, which materializes the complete missing-body vector in one blocking consensus call
- `SyncManager::get_missing_block_body_hashes` then scans for the body boundary and calls `antipast_hashes_between(..., None)` with no result bound
- `SyncManager::antipast_hashes_between` already supports `Some(max_blocks)`, providing a safe basis for a bounded consensus-side query
- current P2P body processing already uses `IBD_BATCH_SIZE = 99`; Phase 4 will first remove the unnecessary full-vector materialization while preserving body ordering and validation rules

Completed precursor work:

âœ… Service State import grouped into one atomic RocksDB WriteBatch
âœ… UTXO writes grouped into one atomic WriteBatch per chunk

These are safe foundations but do not replace the Phase 4 tasks above.

Objective:

Reduce random database access and limit CPU/network idle periods.

No change to consensus validity rules.

---

# Phase 5 â€” PoM-compatible IBD

Overall status: â¬œ Planned

â¬œ Detect whether a peer can provide historical PoM proofs
â¬œ Track the oldest available PoM DAA per peer
â¬œ Track PoM proof retention depth
â¬œ Avoid selecting incapable peers for historical IBD
â¬œ Retry missing PoM proofs without rejecting otherwise valid bodies
â¬œ Request PoM proofs independently from bodies
â¬œ Persist downloaded PoM-proof progress
âœ… Add historical PoM transfer/verification metrics

Objective:

A peer that has the blockchain tip must not automatically be assumed capable of supplying all historical PoM data required by IBD.

---

# Phase 6 â€” Peer capability discovery

Overall status: â¬œ Planned

â¬œ Extend peer capability information
â¬œ Advertise header availability
â¬œ Advertise body availability
â¬œ Advertise UTXO/state availability
â¬œ Advertise Service State availability
â¬œ Advertise PoM proof availability
â¬œ Advertise retention depth
â¬œ Advertise oldest available PoM DAA
â¬œ Advertise supported IBD protocol version
â¬œ Advertise maximum supported chunk size

Objective:

Do not waste IBD time discovering too late that a peer cannot serve requested data.

---

# Phase 7 â€” Multi-peer IBD scheduler

Overall status: â¬œ Planned

â¬œ Allow several peers to participate in one IBD session
â¬œ Separate IBD resources by data type
â¬œ Dynamically assign chunks
â¬œ Measure peer bandwidth
â¬œ Measure peer latency
â¬œ Measure peer reliability
â¬œ Reassign chunks on timeout
â¬œ Reassign chunks after disconnect
â¬œ Penalize consistently unreliable peers
â¬œ Do not globally ban peers for simple IBD capability limitations

Objective:

A slow or incomplete peer must no longer determine the speed of the entire IBD.

---

# Phase 8 â€” Content-addressed state chunks

Overall status: â¬œ Planned

â¬œ Define canonical chunk serialization
â¬œ Hash each chunk
â¬œ Bind chunks to a pruning point
â¬œ Bind chunks to a global state commitment
â¬œ Detect duplicate chunks
â¬œ Allow chunks from different providers
â¬œ Verify chunks before permanent acceptance
â¬œ Cache locally verified chunks

Objective:

Provider identity becomes secondary. Only cryptographic content matters.

---

# Phase 9 â€” Fast state distribution

Overall status: â¬œ Planned

â¬œ Keep P2P as the primary transport
â¬œ Allow multiple state providers
â¬œ Allow community mirrors
â¬œ Allow pool-operated mirrors
â¬œ Allow exchange-operated mirrors
â¬œ Optional HTTPS transport
â¬œ Optional CDN transport
â¬œ Same content regardless of transport
â¬œ Same cryptographic verification regardless of source

Objective:

HTTP/HTTPS may improve availability and throughput but must never become a trust requirement.

---

# Phase 10 â€” NAT / CGNAT-compatible IBD

Overall status: â¬œ Planned

â¬œ Require only outbound connections for standard nodes
â¬œ Do not require port forwarding to synchronize
â¬œ Keep inbound P2P optional
â¬œ Optional UPnP support
â¬œ Optional NAT-PMP support
â¬œ Optional PCP support
â¬œ P2P fallback across multiple outbound peers
â¬œ HTTPS/443 fallback when P2P is blocked

Mandatory objective:

A new user behind CGNAT with zero inbound ports must be able to start `keryxd`, discover peers, download state, verify everything locally and reach `SYNCED`.

---

# Phase 11 â€” Recovery and adversarial testing

Overall status: ðŸŸ¨ Partially prepared, real campaign pending

â¬œ Disconnect a peer during header synchronization
ðŸ§ª Disconnect/kill during UTXO synchronization
ðŸ§ª Disconnect/kill during Service State synchronization
â¬œ Disconnect a peer during PoM synchronization
ðŸŸ¨ Kill the node process during every IBD stage
ðŸ§ª Restart after partial UTXO/Service State download
ðŸ§ª Change provider during UTXO/Service State recovery
â¬œ Send an invalid state chunk
â¬œ Send a corrupted PoM proof
â¬œ Send duplicate chunks
â¬œ Send chunks in the wrong order
â¬œ Peer advertises data it does not actually possess
â¬œ Peer becomes extremely slow
âœ… Reject checkpoints for a stale pruning point
â¬œ Multiple peers send contradictory data
â¬œ All optional mirrors unavailable
â¬œ P2P-only synchronization remains functional

UTXO and Service State fault points are already implemented and locally CI-certified. Their mainnet validation remains pending while test nodes are unavailable.

Objective:

IBD must fail cleanly and resume efficiently.

---

# Phase 12 â€” Performance validation

Overall status: ðŸŸ¨ Baseline available, IBD v2 comparison not yet executed

The original roadmap referred to Keryx v1.5.4 as the baseline. The project later froze the active comparison baseline on **Keryx v1.5.5**, commit `bb408d54ca3992f7f9f4e269507f7603c234d24d`, to remain aligned with current upstream compatibility.

âœ… Establish canonical baseline: RUN A v1.5.5 = 95.17 min
â¬œ Compare IBD v2 against baseline
â¬œ Test on HDD
â¬œ Test on SATA SSD
âœ… Test baseline on NVMe
â¬œ Test with low RAM
âœ… Test baseline with high RAM
â¬œ Test with slow Internet
â¬œ Test with high latency
â¬œ Test with packet loss
ðŸŸ¨ Test with one peer
â¬œ Test with multiple peers in the Phase 7 scheduler sense
â¬œ Test a CGNAT / outbound-only node

Measure:

- total IBD duration
- network traffic
- peak RAM
- CPU usage
- disk I/O
- recovery time after restart
- amount of unnecessarily downloaded data
- peer utilization

---

# Phase 13 â€” Protocol deployment

Overall status: â¬œ Planned

â¬œ Define a Keryx IBD protocol version
â¬œ Maintain compatibility with old peers
â¬œ Negotiate capabilities during handshake
â¬œ Activate IBD v2 only if both peers support it
â¬œ Automatically fall back to legacy IBD
â¬œ Test mixed networks
â¬œ Test gradual deployment
â¬œ Document operator requirements

Target:

New node + New peer â†’ IBD v2

New node + Old peer â†’ legacy IBD

Old node + New peer â†’ legacy IBD

No forced network-wide update is required for the first deployment.

---

# Security principles

âœ… No trusted blockchain snapshot

âœ… No mandatory central server

âœ… No mandatory Keryx Labs endpoint

âœ… No mandatory pool endpoint

âœ… No DNS seed as a trust source

âœ… No inbound port required by the final design

âœ… Every state commitment verified locally

âœ… Every block verified locally

âœ… Every PoM proof verified locally

âœ… Transport source never determines validity

---

# Mandatory implementation order

1. Phase 0 â€” Instrumentation
2. Phase 1 â€” Resumable Service State
3. Phase 2 â€” Resumable UTXO
4. Phase 3 â€” Independent IBD stage tracking
5. Phase 4 â€” Database batching
6. Phase 5 â€” PoM-compatible IBD
7. Phase 6 â€” Peer capabilities
8. Phase 7 â€” Multi-peer scheduler
9. Phase 8 â€” Content-addressed chunks
10. Phase 9 â€” Fast state distribution
11. Phase 10 â€” NAT / CGNAT support
12. Phase 11 â€” Adversarial testing
13. Phase 12 â€” Performance validation
14. Phase 13 â€” Progressive protocol deployment

**Working rule: do not renumber, merge or advance a phase out of this order without an explicit project decision.**
