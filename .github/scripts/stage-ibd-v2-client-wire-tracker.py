from pathlib import Path

path = Path("protocol/flows/src/ibd/flow.rs")
text = path.read_text(encoding="utf-8")

old_import = "    ibd_v2::metrics::{StageMetrics, metrics_enabled},\n"
new_import = """    ibd_v2::{
        metrics::{StageMetrics, metrics_enabled},
        service_state::ServiceStateWireTracker,
    },
"""
if text.count(old_import) != 1:
    raise SystemExit("ibd-v2 import anchor mismatch")
text = text.replace(old_import, new_import, 1)

old_tracker = """        let mut acc = MuHash::new();
        let mut metrics = StageMetrics::new();
        loop {
"""
new_tracker = """        let mut acc = MuHash::new();
        let mut metrics = StageMetrics::new();
        let mut resume_tracker = crate::ibd_v2::enabled_from_env().then(|| ServiceStateWireTracker::new(pruning_point));
        loop {
"""
if text.count(old_tracker) != 1:
    raise SystemExit("service-state tracker anchor mismatch")
text = text.replace(old_tracker, new_tracker, 1)

old_chunk = """                    Some(Payload::ServiceStateChunk(chunk)) => {
                        if metrics_enabled() {
"""
new_chunk = """                    Some(Payload::ServiceStateChunk(chunk)) => {
                        if let Some(tracker) = &mut resume_tracker {
                            let chunk_pruning_point: Option<Hash> =
                                chunk.pruning_point_hash.clone().map(TryInto::try_into).transpose()?;
                            tracker
                                .accept_chunk(chunk_pruning_point, chunk.start_cursor, chunk.next_cursor, &chunk.rows)
                                .map_err(|err| {
                                    ProtocolError::OtherOwned(format!(
                                        "invalid IBD v2 service-state chunk metadata: {err:?}"
                                    ))
                                })?;
                        }
                        if metrics_enabled() {
"""
if text.count(old_chunk) != 1:
    raise SystemExit("service-state chunk anchor mismatch")
text = text.replace(old_chunk, new_chunk, 1)

old_done = """                    Some(Payload::DoneServiceStateChunks(_)) => break,
"""
new_done = """                    Some(Payload::DoneServiceStateChunks(done)) => {
                        if let Some(tracker) = &mut resume_tracker {
                            let done_pruning_point: Option<Hash> =
                                done.pruning_point_hash.map(TryInto::try_into).transpose()?;
                            tracker.accept_done(done_pruning_point, done.next_cursor).map_err(|err| {
                                ProtocolError::OtherOwned(format!(
                                    "invalid IBD v2 service-state completion metadata: {err:?}"
                                ))
                            })?;
                        }
                        break;
                    }
"""
if text.count(old_done) != 1:
    raise SystemExit("service-state done anchor mismatch")
text = text.replace(old_done, new_done, 1)

old_after_loop = """        // Mirror `commitment_at` exactly: no rows seals nothing, and the expected value is then
"""
new_after_loop = """        if let Some(tracker) = resume_tracker {
            let checkpoint = tracker.metadata();
            debug!(
                "IBD v2 service-state wire mode={:?} checkpoint_cursor={} checkpoint_chunks={} checkpoint_rows={}",
                tracker.mode(), checkpoint.next_cursor, checkpoint.chunk_count, checkpoint.row_count
            );
        }
        // Mirror `commitment_at` exactly: no rows seals nothing, and the expected value is then
"""
if text.count(old_after_loop) != 1:
    raise SystemExit("service-state post-loop anchor mismatch")
text = text.replace(old_after_loop, new_after_loop, 1)

path.write_text(text, encoding="utf-8")
