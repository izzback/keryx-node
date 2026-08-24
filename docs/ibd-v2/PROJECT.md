# Keryx IBD v2

## Project baseline

IBD v2 development is intentionally isolated from the rolling Keryx upstream branch.

- Upstream repository: `Keryx-Labs/keryx-node`
- Frozen baseline release: `v1.5.4`
- Frozen baseline commit: `e97dc268b2f7eb16ae761a37c79080a5c5c46ddc`
- Immutable baseline branch: `ibd-v2-base-v1.5.4`
- Development branch: `ibd-v2`

The baseline branch is an anchor only. No IBD v2 development commits should ever be added to it.

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
- download scheduling
- persistence/checkpoints
- resumable state transfer
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

IBD v2 should initially be disabled by default and activated explicitly for development/testing.

Suggested runtime gate:

```text
KERYX_IBD_V2=1
```

Legacy IBD remains available as the fallback until IBD v2 has completed compatibility and adversarial testing.

## Development order

1. Instrument current IBD and establish a v1.5.4 baseline.
2. Add the isolated `ibd_v2` module and compatibility layer.
3. Implement resumable Service State transfer.
4. Implement resumable UTXO transfer.
5. Add independent IBD stage state/checkpoints.
6. Batch consensus/database reads.
7. Add PoM-aware state and peer selection.
8. Add peer capability discovery.
9. Add multi-peer scheduling.
10. Add content-addressed state chunks.
11. Add optional alternate transports only after P2P correctness is proven.

## Non-goal

IBD v2 must never require a single official node, trusted snapshot, pool, DNS seed, HTTP endpoint or mirror in order to synchronize Keryx.
