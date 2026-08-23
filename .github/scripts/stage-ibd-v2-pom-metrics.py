from pathlib import Path

path = Path("protocol/flows/src/ibd/flow.rs")
lines = path.read_text(encoding="utf-8").splitlines()
out = []

function = None
pending_first_merge = False
pending_current_merge = False
body_decode_active = False
counts = {
    "metrics_struct": 0,
    "queue_field": 0,
    "stage_start": 0,
    "first_output": 0,
    "first_merge": 0,
    "current_output": 0,
    "current_merge": 0,
    "validation_wait": 0,
    "summary": 0,
    "full_init": 0,
    "full_wait": 0,
    "full_proof": 0,
    "full_discard": 0,
    "full_reproof": 0,
    "full_return": 0,
    "body_init": 0,
    "body_wait": 0,
    "body_proof": 0,
    "body_decode_start": 0,
    "body_decode_end": 0,
    "body_discard": 0,
    "body_reproof": 0,
    "body_return": 0,
}

for line in lines:
    stripped = line.strip()
    indent = line[: len(line) - len(line.lstrip())]

    if stripped.startswith("async fn "):
        function = stripped.split("async fn ", 1)[1].split("(", 1)[0]

    if stripped == "struct QueueChunkOutput {":
        metrics_struct = [
            "#[derive(Default)]",
            "struct PomChunkMetrics {",
            "    blocks: u64,",
            "    proofs: u64,",
            "    proof_bytes: u64,",
            "    reproofs_queued: u64,",
            "    discarded_historical_proofs: u64,",
            "    discarded_historical_bytes: u64,",
            "    decode_time: Duration,",
            "    peer_wait_time: Duration,",
            "}",
            "",
            "impl PomChunkMetrics {",
            "    fn merge(&mut self, other: Self) {",
            "        self.blocks = self.blocks.saturating_add(other.blocks);",
            "        self.proofs = self.proofs.saturating_add(other.proofs);",
            "        self.proof_bytes = self.proof_bytes.saturating_add(other.proof_bytes);",
            "        self.reproofs_queued = self.reproofs_queued.saturating_add(other.reproofs_queued);",
            "        self.discarded_historical_proofs =",
            "            self.discarded_historical_proofs.saturating_add(other.discarded_historical_proofs);",
            "        self.discarded_historical_bytes =",
            "            self.discarded_historical_bytes.saturating_add(other.discarded_historical_bytes);",
            "        self.decode_time = self.decode_time.saturating_add(other.decode_time);",
            "        self.peer_wait_time = self.peer_wait_time.saturating_add(other.peer_wait_time);",
            "    }",
            "}",
            "",
        ]
        out.extend(metrics_struct)
        counts["metrics_struct"] += 1
        out.append(line)
        continue

    if stripped == "timestamp: u64," and counts["queue_field"] == 0:
        out.append(line)
        out.append(f"{indent}pom: PomChunkMetrics,")
        counts["queue_field"] += 1
        continue

    if function == "sync_missing_block_bodies" and stripped == "let high_daa = high_header.daa_score;":
        out.append(line)
        out.append(f"{indent}let pom_stage_started = metrics_enabled().then(Instant::now);")
        out.append(f"{indent}let mut pom_totals = PomChunkMetrics::default();")
        out.append(f"{indent}let mut validation_blocked = Duration::ZERO;")
        counts["stage_start"] += 1
        continue

    if function == "sync_missing_block_bodies" and stripped.startswith(
        "let QueueChunkOutput { jobs: mut prev_jobs, daa_score: mut prev_daa_score, timestamp: mut prev_timestamp } ="
    ):
        out.extend(
            [
                f"{indent}let QueueChunkOutput {{",
                f"{indent}    jobs: mut prev_jobs,",
                f"{indent}    daa_score: mut prev_daa_score,",
                f"{indent}    timestamp: mut prev_timestamp,",
                f"{indent}    pom: first_pom,",
                f"{indent}}} =",
            ]
        )
        pending_first_merge = True
        counts["first_output"] += 1
        continue

    if function == "sync_missing_block_bodies" and pending_first_merge and stripped.endswith(".await?;"):
        out.append(line)
        out.append(f"{indent}pom_totals.merge(first_pom);")
        pending_first_merge = False
        counts["first_merge"] += 1
        continue

    if function == "sync_missing_block_bodies" and stripped.startswith(
        "let QueueChunkOutput { jobs: current_jobs, daa_score: current_daa_score, timestamp: current_timestamp } ="
    ):
        out.extend(
            [
                f"{indent}let QueueChunkOutput {{",
                f"{indent}    jobs: current_jobs,",
                f"{indent}    daa_score: current_daa_score,",
                f"{indent}    timestamp: current_timestamp,",
                f"{indent}    pom: current_pom,",
                f"{indent}}} =",
            ]
        )
        pending_current_merge = True
        counts["current_output"] += 1
        continue

    if function == "sync_missing_block_bodies" and pending_current_merge and stripped.endswith(".await?;"):
        out.append(line)
        out.append(f"{indent}pom_totals.merge(current_pom);")
        pending_current_merge = False
        counts["current_merge"] += 1
        continue

    if function == "sync_missing_block_bodies" and stripped == "try_join_all(prev_jobs).await?;":
        out.append(f"{indent}let validation_wait_started = metrics_enabled().then(Instant::now);")
        out.append(line)
        out.append(f"{indent}if let Some(validation_wait_started) = validation_wait_started {{")
        out.append(f"{indent}    validation_blocked = validation_blocked.saturating_add(validation_wait_started.elapsed());")
        out.append(f"{indent}}}")
        counts["validation_wait"] += 1
        continue

    if function == "sync_missing_block_bodies" and stripped == "progress_reporter.report_completion(prev_chunk_len);":
        out.append(line)
        out.append(f"{indent}if metrics_enabled() {{")
        out.append(f"{indent}    let elapsed = pom_stage_started.expect(\"metrics start is present when metrics are enabled\").elapsed();")
        out.append(f"{indent}    let elapsed_seconds = elapsed.as_secs_f64();")
        out.append(f"{indent}    let blocks_per_second = if elapsed_seconds == 0.0 {{ 0.0 }} else {{ pom_totals.blocks as f64 / elapsed_seconds }};")
        out.append(f"{indent}    let proof_megabytes_per_second =")
        out.append(f"{indent}        if elapsed_seconds == 0.0 {{ 0.0 }} else {{ (pom_totals.proof_bytes as f64 / 1_000_000.0) / elapsed_seconds }};")
        out.append(f"{indent}    let peer_wait_ratio =")
        out.append(f"{indent}        if elapsed_seconds == 0.0 {{ 0.0 }} else {{ (pom_totals.peer_wait_time.as_secs_f64() / elapsed_seconds).clamp(0.0, 1.0) }};")
        out.append(f"{indent}    info!(")
        out.append(f"{indent}        \"IBD-V2-METRICS: stage=pom-body-sync mode={{}} complete=true blocks={{}} proofs={{}} proof_bytes={{}} proof_bytes_measured={{}} reproofs_queued={{}} discarded_historical_proofs={{}} discarded_historical_bytes={{}} elapsed={{:.3}}s rate={{:.2}} blocks/s proof_throughput={{:.2}} MB/s peer_wait={{:.3}}s peer_wait_pct={{:.1}}% decode={{:.3}}s validation_blocked={{:.3}}s\",")
        out.append(f"{indent}        if self.body_only_ibd_permitted {{ \"body-only\" }} else {{ \"full-block\" }},")
        out.append(f"{indent}        pom_totals.blocks,")
        out.append(f"{indent}        pom_totals.proofs,")
        out.append(f"{indent}        pom_totals.proof_bytes,")
        out.append(f"{indent}        self.body_only_ibd_permitted,")
        out.append(f"{indent}        pom_totals.reproofs_queued,")
        out.append(f"{indent}        pom_totals.discarded_historical_proofs,")
        out.append(f"{indent}        pom_totals.discarded_historical_bytes,")
        out.append(f"{indent}        elapsed_seconds,")
        out.append(f"{indent}        blocks_per_second,")
        out.append(f"{indent}        proof_megabytes_per_second,")
        out.append(f"{indent}        pom_totals.peer_wait_time.as_secs_f64(),")
        out.append(f"{indent}        peer_wait_ratio * 100.0,")
        out.append(f"{indent}        pom_totals.decode_time.as_secs_f64(),")
        out.append(f"{indent}        validation_blocked.as_secs_f64()")
        out.append(f"{indent}    );")
        out.append(f"{indent}}}")
        counts["summary"] += 1
        continue

    if function == "queue_block_processing_chunk_full_block" and stripped == "let mut current_timestamp = 0;":
        out.append(line)
        out.append(f"{indent}let mut pom = PomChunkMetrics {{ blocks: chunk.len() as u64, ..Default::default() }};")
        counts["full_init"] += 1
        continue

    if function == "queue_block_processing_chunk_full_block" and stripped == "let msg = dequeue_with_timeout!(self.incoming_route, Payload::IbdBlock)?;":
        out.append(f"{indent}let wait_started = metrics_enabled().then(Instant::now);")
        out.append(line)
        out.append(f"{indent}if let Some(wait_started) = wait_started {{")
        out.append(f"{indent}    pom.peer_wait_time = pom.peer_wait_time.saturating_add(wait_started.elapsed());")
        out.append(f"{indent}}}")
        counts["full_wait"] += 1
        continue

    if function == "queue_block_processing_chunk_full_block" and stripped == "let mut block: Block = Versioned(self.header_format, msg).try_into()?;":
        out.append(line)
        out.append(f"{indent}if metrics_enabled() && block.pom_proof.is_some() {{")
        out.append(f"{indent}    pom.proofs = pom.proofs.saturating_add(1);")
        out.append(f"{indent}}}")
        counts["full_proof"] += 1
        continue

    if function == "queue_block_processing_chunk_full_block" and stripped == "block.pom_tier = block.pom_tier.or_else(|| block.pom_proof.as_ref().map(|p| p.tier));":
        out.append(f"{indent}if metrics_enabled() && block.pom_proof.is_some() {{")
        out.append(f"{indent}    pom.discarded_historical_proofs = pom.discarded_historical_proofs.saturating_add(1);")
        out.append(f"{indent}}}")
        out.append(line)
        counts["full_discard"] += 1
        continue

    if function == "queue_block_processing_chunk_full_block" and stripped == "self.ctx.enqueue_pom_reproof(block.hash());":
        out.append(line)
        out.append(f"{indent}if metrics_enabled() {{")
        out.append(f"{indent}    pom.reproofs_queued = pom.reproofs_queued.saturating_add(1);")
        out.append(f"{indent}}}")
        counts["full_reproof"] += 1
        continue

    if function == "queue_block_processing_chunk_full_block" and stripped == "Ok(QueueChunkOutput { jobs, daa_score: current_daa_score, timestamp: current_timestamp })":
        out.append(f"{indent}Ok(QueueChunkOutput {{ jobs, daa_score: current_daa_score, timestamp: current_timestamp, pom }})")
        counts["full_return"] += 1
        continue

    if function == "queue_block_processing_chunk_body_only" and stripped == "let mut current_timestamp = 0;":
        out.append(line)
        out.append(f"{indent}let mut pom = PomChunkMetrics {{ blocks: chunk.len() as u64, ..Default::default() }};")
        counts["body_init"] += 1
        continue

    if function == "queue_block_processing_chunk_body_only" and stripped == "let msg = dequeue_with_timeout!(self.incoming_route, Payload::BlockBody)?;":
        out.append(f"{indent}let wait_started = metrics_enabled().then(Instant::now);")
        out.append(line)
        out.append(f"{indent}if let Some(wait_started) = wait_started {{")
        out.append(f"{indent}    pom.peer_wait_time = pom.peer_wait_time.saturating_add(wait_started.elapsed());")
        out.append(f"{indent}}}")
        out.append(f"{indent}let proof_bytes = if metrics_enabled() {{")
        out.append(f"{indent}    msg.pom_proof.as_deref().map(|proof| proof.len() as u64).unwrap_or(0)")
        out.append(f"{indent}}} else {{")
        out.append(f"{indent}    0")
        out.append(f"{indent}}};")
        out.append(f"{indent}if proof_bytes > 0 {{")
        out.append(f"{indent}    pom.proofs = pom.proofs.saturating_add(1);")
        out.append(f"{indent}    pom.proof_bytes = pom.proof_bytes.saturating_add(proof_bytes);")
        out.append(f"{indent}}}")
        counts["body_wait"] += 1
        counts["body_proof"] += 1
        continue

    if function == "queue_block_processing_chunk_body_only" and stripped == "let pom_proof = msg":
        out.append(f"{indent}let decode_started = metrics_enabled().then(Instant::now);")
        out.append(line)
        body_decode_active = True
        counts["body_decode_start"] += 1
        continue

    if function == "queue_block_processing_chunk_body_only" and body_decode_active and stripped == ".map(Arc::new);":
        out.append(line)
        out.append(f"{indent}if let Some(decode_started) = decode_started {{")
        out.append(f"{indent}    pom.decode_time = pom.decode_time.saturating_add(decode_started.elapsed());")
        out.append(f"{indent}}}")
        body_decode_active = False
        counts["body_decode_end"] += 1
        continue

    if function == "queue_block_processing_chunk_body_only" and stripped == "(None, pom_tier.or_else(|| pom_proof.as_ref().map(|p| p.tier)))":
        out.append(f"{indent}{{")
        out.append(f"{indent}    if metrics_enabled() && pom_proof.is_some() {{")
        out.append(f"{indent}        pom.discarded_historical_proofs = pom.discarded_historical_proofs.saturating_add(1);")
        out.append(f"{indent}        pom.discarded_historical_bytes = pom.discarded_historical_bytes.saturating_add(proof_bytes);")
        out.append(f"{indent}    }}")
        out.append(f"{indent}    (None, pom_tier.or_else(|| pom_proof.as_ref().map(|p| p.tier)))")
        out.append(f"{indent}}}")
        counts["body_discard"] += 1
        continue

    if function == "queue_block_processing_chunk_body_only" and stripped == "self.ctx.enqueue_pom_reproof(blk_header.hash);":
        out.append(line)
        out.append(f"{indent}if metrics_enabled() {{")
        out.append(f"{indent}    pom.reproofs_queued = pom.reproofs_queued.saturating_add(1);")
        out.append(f"{indent}}}")
        counts["body_reproof"] += 1
        continue

    if function == "queue_block_processing_chunk_body_only" and stripped == "Ok(QueueChunkOutput { jobs, daa_score: current_daa_score, timestamp: current_timestamp })":
        out.append(f"{indent}Ok(QueueChunkOutput {{ jobs, daa_score: current_daa_score, timestamp: current_timestamp, pom }})")
        counts["body_return"] += 1
        continue

    out.append(line)

expected = {
    "metrics_struct": 1,
    "queue_field": 1,
    "stage_start": 1,
    "first_output": 1,
    "first_merge": 1,
    "current_output": 1,
    "current_merge": 1,
    "validation_wait": 2,
    "summary": 1,
    "full_init": 1,
    "full_wait": 1,
    "full_proof": 1,
    "full_discard": 1,
    "full_reproof": 1,
    "full_return": 1,
    "body_init": 1,
    "body_wait": 1,
    "body_proof": 1,
    "body_decode_start": 1,
    "body_decode_end": 1,
    "body_discard": 1,
    "body_reproof": 1,
    "body_return": 1,
}
if counts != expected:
    raise SystemExit(f"patch anchors mismatch: {counts}")

path.write_text("\n".join(out) + "\n", encoding="utf-8")
