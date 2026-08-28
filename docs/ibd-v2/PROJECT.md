# Keryx IBD v2

## Project baseline

IBD v2 development is intentionally isolated from the rolling Keryx upstream branch.

- Upstream repository: `Keryx-Labs/keryx-node`
- Frozen upstream release: `v1.5.5`
- Frozen upstream commit: `bb408d54ca3992f7f9f4e269507f7603c234d24d`
- Immutable upstream baseline branch: `ibd-v2-base-v1.5.5`
- Validated integration branch: `ibd-v2-integrate-v1.5.5`
- Current technical development branch: `ibd-v2-phase3-persistent-state`
- Canonical roadmap: `docs/ibd-v2/ROADMAP.md`
- Canonical French roadmap: `docs/ibd-v2/ROADMAP-FR.md`
- Canonical RUN A report: `docs/ibd-v2/RUN-A-BASELINE-v1.5.5.md`

The current branch name is historical/technical only. It does **not** redefine roadmap phase numbering.

The baseline/reference branches are anchors only. Development commits must never be added to them.

## Canonical RUN A

The v1.5.5 RUN A baseline is frozen before behavioral optimization work.

- IBD v2 behavior: disabled (`KERYX_IBD_V2=0`)
- IBD v2 metrics: enabled (`KERYX_IBD_V2_METRICS=1`)
- Fresh mainnet datadir
- Default Keryx RAM/cache/network/peer settings
- Time to final live synchronization on the baseline host: **95.17 minutes**

RUN A identified peer wait as the dominant PoM/body-sync bottleneck. This measurement guides later phases but does not authorize skipping roadmap order.

## Design rule

IBD v2 must be developed as an isolated subsystem rather than as a rewrite of the legacy IBD implementation.

Preferred layout:

```text
protocol/flows/src/
├── ibd/                 # legacy Keryx IBD; keep changes minimal
└── ibd_v2/              # new implementation
    ├── mod.rs
    ├── compat.rs        # narrow adapter to current Keryx APIs
    ├── metrics.rs
    ├── state.rs
    ├── checkpoint.rs
    ├── service_state.rs
    ├── utxo_recovery.rs
    ├── pom.rs
    ├── scheduler.rs
    └── peer_caps.rs
```

`compat.rs` is the main isolation boundary. Calls into Keryx consensus, storage and P2P APIs should be concentrated there whenever practical. When upstream APIs change, update the compatibility layer instead of rewriting the IBD v2 core.

## Initial safety boundaries

The early roadmap phases must not change consensus validity rules.

Do not modify unless a later reviewed phase explicitly requires it:

- genesis data
- hardfork activation values
- PoW / PoM validity rules
- transaction validity rules
- block hashing or serialization
- existing consensus commitments

IBD v2 work may change transfer orchestration, temporary persistence, checkpointing, batching, peer selection and transport, while all received data remains locally verified using normal Keryx consensus rules.

## Compatibility principle

The transport source is never a source of trust.

```text
remote peer / future mirror
        |
        v
IBD v2 transport
        |
        v
staging/checkpoint storage
        |
        v
local cryptographic verification
        |
        v
normal Keryx consensus validation
        |
        v
durable commit
```

## Activation strategy

IBD v2 remains disabled by default and is activated explicitly for development/testing.

```text
KERYX_IBD_V2=1
```

Legacy IBD remains the fallback until the roadmap deployment phase explicitly changes activation behavior.

## Canonical implementation order

The project follows this order and must not silently renumber or reorder it:

1. **Phase 0 — IBD instrumentation**
2. **Phase 1 — Resumable Service State synchronization**
3. **Phase 2 — Resumable UTXO state synchronization**
4. **Phase 3 — Independent IBD stage tracking**
5. **Phase 4 — Database batching and validation**
6. **Phase 5 — PoM-compatible IBD**
7. **Phase 6 — Peer capability discovery**
8. **Phase 7 — Multi-peer IBD scheduler**
9. **Phase 8 — Content-addressed state chunks**
10. **Phase 9 — Fast state distribution**
11. **Phase 10 — NAT / CGNAT-compatible IBD**
12. **Phase 11 — Recovery and adversarial testing**
13. **Phase 12 — Performance validation**
14. **Phase 13 — Progressive protocol deployment**

The detailed requirements and status of every phase live in `ROADMAP.md` / `ROADMAP-FR.md` and are authoritative.

## Current status under the canonical roadmap

- **Phase 0:** instrumentation is very advanced; direct fine-grained RocksDB latency instrumentation remains incomplete.
- **Phase 1:** resumable Service State is implemented and CI-certified; real mainnet recovery testing remains pending.
- **Phase 2:** resumable UTXO is implemented and CI-certified using a durable outpoint anchor compatible with v1.5.5 peers; real mainnet recovery testing remains pending.
- **Phase 3:** independent UTXO and Service State tracking are wired; Headers, Pruning, PoM and Bodies still need equivalent effective stage tracking.
- **Phase 4:** next only after Phase 3 implementation wiring is complete. Some atomic WriteBatch groundwork already exists but does not count as completion of Phase 4.
- **Phase 5 and later:** do not begin early without an explicit roadmap decision.

## Immediate development rule

While real nodes are unavailable, work that does not require live mainnet evidence should proceed in canonical order:

```text
finish Phase 3 stage tracking
        |
        v
Phase 4 database/validation batching
        |
        v
Phase 5 PoM compatibility
        |
        v
Phase 6 peer capabilities
        ...
```

Real crash/restart evidence for the already implemented Phase 1 and Phase 2 recovery paths is recorded when nodes become available and contributes to Phase 11 adversarial validation. It does not justify skipping the intervening implementation phases.

## Runner policy

All IBD v2 GitHub Actions certification for this project uses the dedicated local Windows runner only:

```text
[self-hosted, Windows, X64]
```

Do not switch to GitHub-hosted runners if the local runner is offline; jobs must remain queued instead.

## Non-goal

IBD v2 must never require a single official node, trusted snapshot, pool, DNS seed, HTTP endpoint or mirror in order to synchronize Keryx.
