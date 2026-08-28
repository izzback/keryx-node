# Keryx IBD v2

## Project baseline

IBD v2 development is intentionally isolated from the rolling Keryx upstream branch.

- Upstream repository: `Keryx-Labs/keryx-node`
- Frozen upstream release: `v1.5.5`
- Frozen upstream commit: `bb408d54ca3992f7f9f4e269507f7603c234d24d`
- Immutable upstream baseline branch: `ibd-v2-base-v1.5.5`
- Validated integration branch: `ibd-v2-integrate-v1.5.5`
- Phase 3 development branch: `ibd-v2-phase3-persistent-state`
- Canonical RUN A report: `docs/ibd-v2/RUN-A-BASELINE-v1.5.5.md`

The baseline/reference branches are anchors only. No Phase 3 development commits should ever be added to them.

## Canonical RUN A

The v1.5.5 RUN A baseline is frozen before Phase 3 work begins.

- IBD v2 behavior: disabled (`KERYX_IBD_V2=0`)
- IBD v2 metrics: enabled (`KERYX_IBD_V2_METRICS=1`)
- Fresh mainnet datadir
- Default Keryx RAM/cache/network/peer settings
- Time to final live synchronization on the baseline host: **95.17 minutes**

The baseline identified peer wait as the dominant PoM body-sync bottleneck, but throughput/scheduler work is deliberately deferred until persistence and recovery are correct.

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
    ├── utxo.rs
    ├── pom.rs
    ├── scheduler.rs
    └── peer_caps.rs
```

`compat.rs` is the main isolation boundary. Calls into Keryx consensus, storage and P2P APIs should be concentrated there whenever practical. When upstream APIs change, we update the compatibility layer instead of rewriting the IBD v2 core.

## Initial safety boundaries

The first milestones must not change consensus validity rules.

Do not modify unless a later reviewed phase explicitly requires it:

- genesis data
- hardfork activation values
- PoW / PoM validity rules
- transaction validity rules
- block hashing or serialization
- existing consensus commitments

Early IBD v2 work is limited to:

- instrumentation
- persistence/checkpoints
- resumable state transfer
- download scheduling
- database batching
- peer capability discovery
- transport selection

All received data remains locally verified using normal Keryx consensus rules.

## Compatibility principle

The transport source is never a source of trust.

```text
remote peer / mirror
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
commit
```

## Activation strategy

IBD v2 remains disabled by default and is activated explicitly for development/testing.

```text
KERYX_IBD_V2=1
```

Legacy IBD remains the fallback until IBD v2 has completed compatibility, restart/recovery, and adversarial testing.

## Current development order

The v1.5.5 work order is intentionally strict:

1. **Phase 0 — reproducible baseline:** complete; canonical RUN A frozen.
2. **Phase 3 — persistent IBD state & recovery:** current phase.
3. **Phase 1 — scheduler/adaptive budgets:** only after restart correctness is proven.
4. **Phase 2 — throughput/download improvements:** only after scheduler safety.
5. **Comparative benchmark:** repeat the same canonical test methodology against RUN A.

Within Phase 3, implement and validate in this order:

1. Durable stage/checkpoint schema with versioning and integrity checks.
2. Atomic checkpoint persistence and safe load/rejection semantics.
3. Resumable Service State progress.
4. Resumable UTXO progress or a safe explicit restart boundary where partial UTXO import cannot yet be resumed.
5. PoM/body progress boundaries that never advertise work beyond consensus-durable data.
6. Crash/restart tests at each stage boundary.
7. Corrupt/truncated/stale checkpoint adversarial tests.

## Deferred work

Do **not** introduce any of the following during Phase 3:

- multi-peer/chunk scheduling
- HTTP mirrors or alternate transports
- speculative parallelism
- peer racing
- scheduler/adaptive budget optimization
- benchmark-specific tuning

RUN A shows that peer wait is a major performance issue, but correctness and durable restart semantics come first.

## Non-goal

IBD v2 must never require a single official node, trusted snapshot, pool, DNS seed, HTTP endpoint or mirror in order to synchronize Keryx.
