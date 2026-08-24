# IBD v2 Upstream Integration Policy

## Objective

Upstream Keryx releases must never be merged directly into active IBD v2 development without an isolated compatibility pass.

The development branch must remain usable even when `Keryx-Labs/keryx-node` changes rapidly.

## Permanent branches

```text
ibd-v2-base-v1.5.4
    Frozen reference. Never modify.

ibd-v2
    Active IBD v2 development.

master
    May continue to track the normal fork/upstream lifecycle independently of IBD v2.
```

Do not develop IBD v2 directly on `master`.

## When a new upstream release appears

Example: upstream releases `v1.5.5`.

Do not immediately rebase or merge it into `ibd-v2`.

Create a temporary integration branch:

```text
ibd-v2
  |
  +---- ibd-v2-integrate-v1.5.5
                 ^
                 |
           upstream v1.5.5
```

All conflict resolution and compatibility changes happen on the temporary integration branch first.

## Integration gates

An upstream update may enter `ibd-v2` only after all applicable gates pass:

1. Build succeeds on Windows and Linux.
2. Existing Keryx tests pass.
3. Legacy IBD still works.
4. IBD v2 tests pass.
5. Consensus test vectors are unchanged unless the upstream release intentionally changes consensus.
6. No unexpected changes to block acceptance behavior are introduced by IBD v2.
7. A fresh-node IBD test completes.
8. Restart/resume tests complete.
9. PoM historical proof tests complete where applicable.
10. The performance baseline is compared before and after integration.

## Upstream change classification

Every upstream release should be classified before integration.

### Class A — low risk

Examples:

- logging
- CLI documentation
- unrelated wallet/RPC changes
- non-IBD UI/tooling

Can usually be integrated with standard CI.

### Class B — IBD-adjacent

Examples:

- P2P message changes
- pruning changes
- RocksDB/storage changes
- consensus API changes
- peer management changes

Requires IBD regression and restart/resume testing.

### Class C — consensus / PoM critical

Examples:

- PoM proof format or verification
- hardfork activation
- block/header serialization
- pruning commitments
- state commitments
- difficulty rules

Requires full compatibility review before integration.

IBD v2 development should pause integration of a Class C update until the new upstream behavior is understood, but work on the frozen IBD v2 branch may continue in parallel.

## Conflict-minimization rules

To reduce future merge conflicts:

- Put new implementation code under `protocol/flows/src/ibd_v2/`.
- Keep edits to legacy `protocol/flows/src/ibd/` as small adapter hooks.
- Centralize upstream-facing APIs in `ibd_v2/compat.rs`.
- Avoid formatting/refactoring unrelated upstream code.
- Do not rename existing upstream types unless required.
- Do not mix optimization changes with consensus behavior changes in one commit.
- Keep each IBD v2 feature in small, reviewable commits.

## Commit discipline

Preferred commit groups:

```text
ibd-v2(metrics): ...
ibd-v2(checkpoint): ...
ibd-v2(service-state): ...
ibd-v2(utxo): ...
ibd-v2(pom): ...
ibd-v2(peer-caps): ...
ibd-v2(scheduler): ...
ibd-v2(storage): ...
```

This makes individual features easier to replay or adapt onto a future Keryx baseline if necessary.

## Emergency upstream security/consensus fix

If upstream ships a critical fix while IBD v2 is under development:

1. Keep `ibd-v2` untouched.
2. Create an integration branch for the fixed upstream release.
3. Apply/adapt IBD v2 changes there.
4. Run the full critical test set.
5. Promote only the validated integration result.

This prevents an emergency upstream release from destroying or destabilizing the working IBD v2 development line.

## Baseline migration

The frozen branch name records the original project baseline. It should not be moved when Keryx updates.

If IBD v2 is eventually rebased onto a new long-term baseline, create a new immutable anchor instead, for example:

```text
ibd-v2-base-v1.5.4
ibd-v2-base-v1.6.0
```

Historical anchors make regressions and performance comparisons reproducible.
