# Upstream integration validation target

Temporary validation branch only.

- Official base release: `v1.5.4` / `e97dc268b2f7eb16ae761a37c79080a5c5c46ddc`
- PoM v4 SIMD optimization: `38001c23c473214db4cfffc27785835848a7d67b`
- 10-BPS cache/storage optimization: `b74615d96d697756111bd65b86cce7ca04da941a`

This branch must not be promoted until the permanent IBD v2 upstream integration gate passes x86 PoM tests, AArch64 compilation, consensus storage, database, and keryxd checks.
