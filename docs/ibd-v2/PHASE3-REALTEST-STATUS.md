# IBD v2 Phase 3 real-test status

Updated: 2026-08-28

## Certified recovery blocks

- Service State recovery is durable and crash-testable.
- Service State import uses an atomic RocksDB WriteBatch.
- UTXO recovery is durable and crash-testable.
- Imported pruning UTXO network chunks are committed atomically.
- On restart, the node reconciles the durable UTXO prefix from RocksDB, reconstructs MuHash state, skips the already durable network prefix, and writes only the remaining suffix.
- A crash after the final UTXO import is covered by deterministic local replay.
- A crash after the UTXO checkpoint is Committed but before Service State is armed is covered by `utxo-after-committed`.

## Final certified functional candidate

Functional commit:

`d921b29d108cf5d3cb7d4f53addbe81fd0502345`

Focused certification on local runner `Keryx-Node-Windows-01`:

- `cargo check -p keryx-consensus --all-targets` — PASS
- `cargo check -p keryx-p2p-flows --all-targets` — PASS
- `cargo check -p keryxd --all-targets` — PASS
- P2P flows Clippy — PASS
- Double identical pruning UTXO import regression — 1/1 PASS
- UTXO recovery tests — 3/3 PASS
- Service State regression tests — 4/4 PASS

## Permanent gate

The permanent Phase 3 Windows gate must now build the release node and produce the final real-test package from this branch HEAD. The gate remains restricted to `[self-hosted, Windows, X64]`.
