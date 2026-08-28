Keryx IBD V2 - Phase 3 real crash/recovery test

Default dedicated datadir:
E:\datanode\keryx-ibd-v2-phase3-realtest

Recommended first test:
1. Stop every other keryxd instance.
2. Run:
   .\START-SERVICE-STATE-CRASH-TEST.ps1 -FaultPoint service-state-after-import
3. The node intentionally hard-aborts after the atomic Service State RocksDB import but before the recovery checkpoint becomes Committed.
4. Restart the SAME datadir:
   .\RESUME-SERVICE-STATE-CRASH-TEST.ps1
5. Expected: the Verified spool is replayed locally, the deterministic atomic import is safe to repeat, recovery is marked Committed, then IBD continues.
6. Inspect evidence:
   .\INSPECT-PHASE3-RECOVERY.ps1

Other fault points:
- service-state-after-spool-fsync: durable spool leads checkpoint; restart reconciles from spool.
- service-state-after-checkpoint: restart requests from the durable saved cursor.
- service-state-after-verified: restart replays verified spool without network redownload.
- service-state-after-import: restart safely replays after the atomic DB batch committed.

Crash run env (set automatically):
KERYX_IBD_V2=1
KERYX_IBD_V2_METRICS=1
KERYX_IBD_V2_FAULT_INJECTION=1
KERYX_IBD_V2_FAULT_POINT=<selected point>