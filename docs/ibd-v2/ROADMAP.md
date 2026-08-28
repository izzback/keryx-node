# Keryx IBD v2 Roadmap

Updated: 2026-08-28

> This document follows the canonical project order. The current technical branch keeps its historical name `ibd-v2-phase3-persistent-state`, but that branch name does not redefine roadmap phase numbering.

## Status legend

⬜ Planned
🟨 In progress
🧪 In testing
✅ Validated
⛔ Blocked

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

Active frozen comparison base: Keryx v1.5.5, commit `bb408d54ca3992f7f9f4e269507f7603c234d24d`.
Canonical RUN A baseline: **95.17 minutes**.

---

# Phase 0 — IBD instrumentation

Overall status: 🟨 Very advanced

✅ Add detailed metrics for the main IBD stages
✅ Measure header download throughput
✅ Measure body download throughput
✅ Measure PoM proof throughput
✅ Measure UTXO download throughput
✅ Measure Service State throughput
✅ Measure network bandwidth usage
🟨 Measure validation CPU time with sufficiently fine granularity
⬜ Measure direct RocksDB read/write latency per IBD operation
✅ Measure peer wait / idle time
✅ Measure time spent in the main IBD stages

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

# Phase 1 — Resumable Service State synchronization

Overall status: 🧪 Implemented and CI-certified, real mainnet testing pending

✅ Add chunk identifiers / cursors
✅ Add durable temporary Service State storage
✅ Persist download progress
✅ Persist the current cursor
✅ Persist verification progress (`DOWNLOADING` / `VERIFIED` / `COMMITTED`)
🧪 Resume after node crash
🧪 Resume after node update
🧪 Resume after peer disconnect
🧪 Resume from another peer
✅ Verify the final Service State commitment
✅ Atomically commit verified state through RocksDB WriteBatch

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

# Phase 2 — Resumable UTXO state synchronization

Overall status: 🧪 Implemented and CI-certified, real mainnet testing pending

🟨 Add deterministic cursors for UTXO chunks

Compatibility note: the first implementation uses a deterministic anchor on the last durable outpoint because current v1.5.5 peers cannot seek directly into the UTXO stream. A non-seeking peer resends the prefix, which is verified/drained to the durable anchor. A true network cursor can be added later without losing backward compatibility.

✅ Use temporary/durable UTXO storage

Implementation note: the existing pruning UTXO RocksDB is reused instead of creating a redundant second database.

✅ Persist completed chunks with an atomic WriteBatch per chunk
✅ Persist progress metadata
🧪 Resume after restart
🧪 Resume after network interruption
🧪 Resume from another peer
✅ Verify the complete UTXO commitment by reconstructing MuHash
🧪 Transition to verified/committed UTXO state with safe recovery around the boundary

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

# Phase 3 — Independent IBD stage tracking

Overall status: 🟨 In progress

🟨 Track Headers independently
🟨 Track Pruning independently
✅ Track UTXO independently
✅ Track Service State independently
🟨 Track PoM independently
🟨 Track Bodies independently

Implemented checkpoint states:

NOT_STARTED
DOWNLOADING
VERIFIED
COMMITTED

The durable checkpoint format is already:

- versioned
- protected by a cryptographic checksum
- bound to network/genesis
- bound to pruning point
- atomically replaced
- able to reject corruption, truncation, unsupported versions and stale checkpoints

UTXO and Service State already use these states for real recovery logic.
Headers, Pruning, PoM and Bodies still need equivalent effective wiring before Phase 3 can be considered ✅.

Objective:

Make IBD recoverable instead of treating synchronization as one large all-or-nothing operation.

---

# Phase 4 — Database batching and validation

Overall status: 🟨 Next offline development priority

⬜ Batch header lookups
⬜ Batch block-status lookups
⬜ Batch missing-body queries
⬜ Use RocksDB `multi_get` where appropriate
⬜ Reduce repeated async consensus calls
⬜ Pipeline network download and validation
⬜ Pipeline validation and database writes
⬜ Dynamically adjust IBD batch sizes
⬜ Add queue backpressure

Completed precursor work:

✅ Service State import grouped into one atomic RocksDB WriteBatch
✅ UTXO writes grouped into one atomic WriteBatch per chunk

These are safe foundations but do not replace the Phase 4 tasks above.

Objective:

Reduce random database access and limit CPU/network idle periods.

No consensus modification.

---

# Phase 5 — PoM-compatible IBD

Overall status: ⬜ Planned

⬜ Detect whether a peer can provide historical PoM proofs
⬜ Track the oldest available PoM DAA per peer
⬜ Track PoM proof retention depth
⬜ Avoid selecting incapable peers for historical IBD
⬜ Retry missing PoM proofs without rejecting otherwise valid bodies
⬜ Request PoM proofs independently from bodies
⬜ Persist downloaded PoM-proof progress
✅ Add historical PoM transfer/verification metrics

Objective:

A peer that has the blockchain tip must not automatically be assumed capable of supplying all historical PoM data required by IBD.

---

# Phase 6 — Peer capability discovery

Overall status: ⬜ Planned

⬜ Extend peer capability information
⬜ Advertise header availability
⬜ Advertise body availability
⬜ Advertise UTXO/state availability
⬜ Advertise Service State availability
⬜ Advertise PoM proof availability
⬜ Advertise retention depth
⬜ Advertise oldest available PoM DAA
⬜ Advertise supported IBD protocol version
⬜ Advertise maximum supported chunk size

Objective:

Do not waste IBD time discovering too late that a peer cannot serve requested data.

---

# Phase 7 — Multi-peer IBD scheduler

Overall status: ⬜ Planned

⬜ Allow several peers to participate in one IBD session
⬜ Separate IBD resources by data type
⬜ Dynamically assign chunks
⬜ Measure peer bandwidth
⬜ Measure peer latency
⬜ Measure peer reliability
⬜ Reassign chunks on timeout
⬜ Reassign chunks after disconnect
⬜ Penalize consistently unreliable peers
⬜ Do not globally ban peers for simple IBD capability limitations

Objective:

A slow or incomplete peer must no longer determine the speed of the entire IBD.

---

# Phase 8 — Content-addressed state chunks

Overall status: ⬜ Planned

⬜ Define canonical chunk serialization
⬜ Hash each chunk
⬜ Bind chunks to a pruning point
⬜ Bind chunks to a global state commitment
⬜ Detect duplicate chunks
⬜ Allow chunks from different providers
⬜ Verify chunks before permanent acceptance
⬜ Cache locally verified chunks

Objective:

Provider identity becomes secondary. Only cryptographic content matters.

---

# Phase 9 — Fast state distribution

Overall status: ⬜ Planned

⬜ Keep P2P as the primary transport
⬜ Allow multiple state providers
⬜ Allow community mirrors
⬜ Allow pool-operated mirrors
⬜ Allow exchange-operated mirrors
⬜ Optional HTTPS transport
⬜ Optional CDN transport
⬜ Same content regardless of transport
⬜ Same cryptographic verification regardless of source

Objective:

HTTP/HTTPS may improve availability and throughput but must never become a trust requirement.

---

# Phase 10 — NAT / CGNAT-compatible IBD

Overall status: ⬜ Planned

⬜ Require only outbound connections for standard nodes
⬜ Do not require port forwarding to synchronize
⬜ Keep inbound P2P optional
⬜ Optional UPnP support
⬜ Optional NAT-PMP support
⬜ Optional PCP support
⬜ P2P fallback across multiple outbound peers
⬜ HTTPS/443 fallback when P2P is blocked

Mandatory objective:

A new user behind CGNAT with zero inbound ports must be able to start `keryxd`, discover peers, download state, verify everything locally and reach `SYNCED`.

---

# Phase 11 — Recovery and adversarial testing

Overall status: 🟨 Partially prepared, real campaign pending

⬜ Disconnect a peer during header synchronization
🧪 Disconnect/kill during UTXO synchronization
🧪 Disconnect/kill during Service State synchronization
⬜ Disconnect a peer during PoM synchronization
🟨 Kill the node process during every IBD stage
🧪 Restart after partial UTXO/Service State download
🧪 Change provider during UTXO/Service State recovery
⬜ Send an invalid state chunk
⬜ Send a corrupted PoM proof
⬜ Send duplicate chunks
⬜ Send chunks in the wrong order
⬜ Peer advertises data it does not actually possess
⬜ Peer becomes extremely slow
✅ Reject checkpoints for a stale pruning point
⬜ Multiple peers send contradictory data
⬜ All optional mirrors unavailable
⬜ P2P-only synchronization remains functional

UTXO and Service State fault points are already implemented and locally CI-certified. Their mainnet validation remains pending while test nodes are unavailable.

Objective:

IBD must fail cleanly and resume efficiently.

---

# Phase 12 — Performance validation

Overall status: 🟨 Baseline available, IBD v2 comparison not yet executed

The original roadmap referred to Keryx v1.5.4 as the baseline. The project later froze the active comparison baseline on **Keryx v1.5.5**, commit `bb408d54ca3992f7f9f4e269507f7603c234d24d`, to remain aligned with current upstream compatibility.

✅ Establish canonical baseline: RUN A v1.5.5 = 95.17 min
⬜ Compare IBD v2 against baseline
⬜ Test on HDD
⬜ Test on SATA SSD
✅ Test baseline on NVMe
⬜ Test with low RAM
✅ Test baseline with high RAM
⬜ Test with slow Internet
⬜ Test with high latency
⬜ Test with packet loss
🟨 Test with one peer
⬜ Test with multiple peers in the Phase 7 scheduler sense
⬜ Test a CGNAT / outbound-only node

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

# Phase 13 — Protocol deployment

Overall status: ⬜ Planned

⬜ Define a Keryx IBD protocol version
⬜ Maintain compatibility with old peers
⬜ Negotiate capabilities during handshake
⬜ Activate IBD v2 only if both peers support it
⬜ Automatically fall back to legacy IBD
⬜ Test mixed networks
⬜ Test gradual deployment
⬜ Document operator requirements

Target:

New node + New peer → IBD v2

New node + Old peer → legacy IBD

Old node + New peer → legacy IBD

No forced network-wide update is required for the first deployment.

---

# Security principles

✅ No trusted blockchain snapshot

✅ No mandatory central server

✅ No mandatory Keryx Labs endpoint

✅ No mandatory pool endpoint

✅ No DNS seed as a trust source

✅ No inbound port required by the final design

✅ Every state commitment verified locally

✅ Every block verified locally

✅ Every PoM proof verified locally

✅ Transport source never determines validity

---

# Mandatory implementation order

1. Phase 0 — Instrumentation
2. Phase 1 — Resumable Service State
3. Phase 2 — Resumable UTXO
4. Phase 3 — Independent IBD stage tracking
5. Phase 4 — Database batching
6. Phase 5 — PoM-compatible IBD
7. Phase 6 — Peer capabilities
8. Phase 7 — Multi-peer scheduler
9. Phase 8 — Content-addressed chunks
10. Phase 9 — Fast state distribution
11. Phase 10 — NAT / CGNAT support
12. Phase 11 — Adversarial testing
13. Phase 12 — Performance validation
14. Phase 13 — Progressive protocol deployment

**Working rule: do not renumber, merge or advance a phase out of this order without an explicit project decision.**
