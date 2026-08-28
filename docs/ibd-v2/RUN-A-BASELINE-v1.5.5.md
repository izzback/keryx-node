# Keryx IBD v2 — Canonical RUN A baseline (v1.5.5)

## Verdict

RUN A is accepted as the canonical pre-IBD-v2 baseline for the v1.5.5 integration line.

The node started from an empty mainnet application directory with IBD v2 behavior disabled and IBD v2 metrics enabled. No RAM, RocksDB cache, peer-count, or network tuning was supplied. The only explicit node argument was `--appdir`.

The collector was interrupted after synchronization rather than exiting through its `Q` reason path, but the node had already been in normal relay mode for about nine minutes and the collector still performed a graceful CTRL+C shutdown. `keryxd` exited with code 0. This does not invalidate the measured IBD interval.

## Identity

- Node version: `keryxd 1.5.5`
- Official upstream baseline: `bb408d54ca3992f7f9f4e269507f7603c234d24d`
- Tested integration build commit: `8efd28271a6561d51febabb2013e611df1eedd1b`
- `keryxd.exe` SHA-256: `a20a34b3b7bf5f23c9baf69c9948e24b66497eef242cfdb1656c743206532a9e`
- RUN A results ZIP SHA-256: `5cfd13a98643ac6f183eb8c4711898ffce37d8a7802d611ba63f8213d14fa328`

## Test mode

- Mainnet, fresh/empty datadir
- `KERYX_IBD_V2_METRICS=1`
- `KERYX_IBD_V2=0`
- No `--ram-scale` override
- No custom RocksDB cache
- No custom peer limits
- No custom network tuning
- Collector resource interval: 5 seconds
- Collector peer interval: 30 seconds

Host used for this baseline:

- Windows 11 Professional
- AMD Ryzen 9 9950X3D, 16 cores / 32 logical processors
- 64 GiB class system memory

## Timing

- Node start: 2026-08-28 08:59:54 +02:00
- Final successful IBD catch-up: 2026-08-28 10:35:04 +02:00
- Canonical IBD time to live synchronization: **95.17 minutes** (about **1 h 35 min 10 s**)
- Collector/node shutdown: 2026-08-28 10:44:15 +02:00
- Total observed process lifetime: 104.35 minutes
- Post-sync normal relay observation: about 9.18 minutes

After the final IBD completion the node continuously accepted relay blocks and processed live headers/blocks, confirming that it had transitioned out of initial synchronization.

## Major IBD stages

| Stage | Result |
| --- | ---: |
| Initial header stream | 1,316,161 headers in 603.577 s (2,180.60 headers/s) |
| Initial header validation | 1,316,161 headers in 603.708 s |
| UTXO stream | 67,318,051 UTXOs in 374.569 s (179,721 UTXOs/s) |
| UTXO processing/import | 67,318,051 UTXOs in 644.366 s (104,472 UTXOs/s) |
| Service state | 713,726 rows in 7.385 s |
| Initial block-body pass | 1,316,088 blocks in 1,593.627 s (825.84 blocks/s) |
| Final catch-up | completed successfully at 10:35:04 +02:00 |

The node performed several normal catch-up IBD passes before reaching the live tip.

## PoM body-sync baseline

Across all completed PoM body-sync passes recorded during RUN A:

- Blocks traversed: 1,345,747
- Possession proofs received/measured: 29,914
- Proof bytes measured: about **13.68 GB**
- Historical proof bytes discarded: about **10.11 GB**
- Historical proofs discarded: 22,091
- Initial reproofs queued: 1,481
- Total recorded PoM body-sync time: 65.12 minutes
- Total recorded peer-wait time: 61.55 minutes
- Aggregate peer-wait share: **94.5%**

This is the strongest baseline bottleneck signal: body synchronization is overwhelmingly peer/network-wait bound rather than decode or local validation bound.

Three middle catch-up passes were especially peer-bound, each reporting about 99.8% peer wait and roughly 9–10 blocks/s. Later catch-ups improved to roughly 40–49 blocks/s.

## Resource envelope

Measured until final IBD completion:

- Mean sampled process CPU: 10.77%
- Peak sampled process CPU: 88.42%
- Peak working set: about 9.40 GB
- Peak private bytes: about 11.89 GB
- Peak threads: 692
- Mean established TCP connections: 63.8
- Peak established TCP connections: 77

Approximate integrated counters through final sync:

- Network received: about 93.1 GB
- Network sent: about 4.16 GB
- Disk writes (system disk counter): about 185.6 GB
- Process write I/O: about 208.9 GB
- Process read I/O: about 205.7 GB

System-wide network/disk counters can include unrelated host activity and should be treated as environment measurements, not exact protocol byte counts. Process I/O and protocol metrics are the stronger comparison points.

## Memory trajectory

Private memory rose from about 1.2 GB at startup to about 5.2 GB after the initial 1.316M-block body pass, then increased to about 10.1 GB during later PoM catch-up and about 11.9 GB at final synchronization. It remained near that level during the post-sync relay observation. RUN A therefore establishes ~12 GB private memory as the observed upper baseline on this host; this run alone does not prove a leak.

## Warnings/errors to preserve as baseline observations

RUN A logged a large number of network-compatibility warnings from obsolete inbound nodes. These are external peer conditions rather than local IBD correctness failures.

More importantly, RUN A emitted **2,733 `PoM guard-rail` errors** between 09:57 and 10:34, warning that recent blocks were about to be served without their possession proof. All of these occurred before the final live-sync point. The node nevertheless completed IBD and entered normal relay operation.

This condition must remain visible in later comparisons because it can create propagation holes and may interact with recovery/resume behavior. It is not caused by enabling IBD v2 in RUN A, since IBD v2 behavior was explicitly disabled.

One coin-age bucket-underflow warning was also observed during UTXO/service-state reconstruction; the implementation clamped the inconsistent value and stated it would be re-derived at next startup.

## Acceptance criteria

RUN A is frozen as the v1.5.5 baseline because:

1. The test started from an empty datadir.
2. The expected v1.5.5 binary and SHA-256 were verified.
3. IBD v2 behavior was disabled.
4. No performance tuning overrides were used.
5. All major IBD stages completed.
6. The node reached live relay mode and remained there for ~9 minutes.
7. The final node shutdown was graceful and exited with code 0.
8. 1,308 IBD-v2 metric lines and complete CPU/RAM/disk/network/peer traces were captured.

## Next phase

Phase 3 begins from the validated integration branch and targets durable IBD progress/checkpoint state and crash/restart recovery. No scheduler, multi-peer, mirror, or throughput optimization is to be introduced until persistence/recovery correctness is established.
