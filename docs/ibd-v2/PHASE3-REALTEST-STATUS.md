# IBD v2 Phase 3 real-test status

Updated: 2026-08-28

## Certified recovery blocks

- Service State recovery is durable and crash-testable.
- Service State import uses an atomic RocksDB WriteBatch.
- UTXO recovery is durable and crash-testable.
- Imported pruning UTXO network chunks are committed atomically.
- On restart, the node reconciles the durable UTXO prefix from RocksDB, reconstructs MuHash state, skips the already durable network prefix, and writes only the remaining suffix.

## Certified UTXO candidate

Functional commit:

`a4bd564a5e56cc544b69c3cbcc71759523e62baf`

Focused certification on local runner `Keryx-Node-Windows-01`:

- `cargo check -p keryx-consensus --all-targets` — PASS
- `cargo check -p keryx-p2p-flows --all-targets` — PASS
- `cargo check -p keryxd --all-targets` — PASS
- P2P flows Clippy — PASS
- UTXO recovery tests — 3/3 PASS
- Service State regression tests — 4/4 PASS

## Next gate

The permanent Phase 3 Windows gate must build the release node and produce the real-test package from this branch HEAD. The gate remains restricted to `[self-hosted, Windows, X64]`.
