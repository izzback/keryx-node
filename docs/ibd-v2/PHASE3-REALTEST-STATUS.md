# IBD v2 Phase 3 real-test status

Updated: 2026-08-28

## Current state

Phase 3 is advanced but not yet declared complete.

The durable checkpoint foundation, Service State recovery and UTXO recovery are implemented and CI-certified. The remaining work is split into two categories:

1. Offline development still possible now: explicit PoM/block-body durable recovery boundaries and their deterministic tests.
2. Live evidence requiring running nodes: the mainnet hard-crash/restart matrix for Service State, UTXO, and later PoM/bodies.

## Certified recovery blocks

- Versioned/integrity-protected atomic IBD v2 checkpoints.
- Corrupt, truncated, unsupported-version, wrong-network and stale-pruning-point checkpoints are rejected.
- Service State recovery is durable and crash-testable.
- Service State import uses an atomic RocksDB WriteBatch.
- UTXO recovery is durable and crash-testable.
- Imported pruning UTXO network chunks are committed atomically.
- On restart, the node reconciles the durable UTXO prefix from RocksDB, reconstructs MuHash state, skips the already durable network prefix, and writes only the remaining suffix.
- Verified UTXO replay can repeat the final import without network redownload.
- Double import of the same verified pruning snapshot has a passing idempotence regression test.
- A deterministic `utxo-after-committed` crash point covers the final UTXO -> Service State handoff window.

## Final functional recovery commit

`d921b29d108cf5d3cb7d4f53addbe81fd0502345`

Focused local-runner certification included:

- `cargo check -p keryx-consensus --all-targets` — PASS
- `cargo check -p keryx-p2p-flows --all-targets` — PASS
- `cargo check -p keryxd --all-targets` — PASS
- P2P flows Clippy — PASS
- UTXO double-import idempotence test — PASS
- UTXO recovery tests — 3/3 PASS
- Service State recovery tests — 4/4 PASS

## Final real-test package

Permanent Phase 3 Windows gate:

`33182774771` — GREEN

Gate/package head:

`5bb59c04a0fb7c62d870475220822c88a08c93e8`

Runner:

`Keryx-Node-Windows-01` (`self-hosted`, `Windows`, `X64`)

Artifact:

`keryx-ibd-v2-phase3-realtest-5bb59c04a0fb7c62d870475220822c88a08c93e8`

Artifact ZIP SHA-256:

`e1533479c26f62228fb9bc4fd156f47c412be5909db109fc3ad1628c86e13a7b`

`keryxd.exe` SHA-256:

`2e17fb843758b65aea6df53edffa779c8ac57e1e8861903315f59077d7fbd752`

The ZIP digest was independently matched against GitHub's artifact digest. The executable digest was independently matched against the package build manifest.

## Next offline development block

PoM and block bodies are already represented as independent checkpoint stages, but they do not yet have the same explicit durable recovery coordinator/certification as UTXO and Service State.

Next implementation target:

- define safe PoM/body durability boundaries;
- persist only reconstructible body-sync targets;
- derive remaining missing bodies from consensus truth after restart;
- decide whether PoM requires a separate durable cursor or can be derived from durable block/proof state;
- add deterministic hard-crash fault points;
- add unit/integration restart tests;
- include them in the permanent local Windows Phase 3 gate.

## Live-test blocker

The actual mainnet crash/restart campaign is intentionally pending until the test nodes can run. No historical production datadir should be modified for these tests.

See:

- `docs/ibd-v2/ROADMAP.md`
- `docs/ibd-v2/ROADMAP-FR.md`
