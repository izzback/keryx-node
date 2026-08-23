from pathlib import Path

path = Path("protocol/flows/src/ibd/flow.rs")
lines = path.read_text(encoding="utf-8").splitlines()
out = []

function = None
inside_append = False
counts = {
    "stage": 0,
    "chunk": 0,
    "append_start": 0,
    "append_end": 0,
    "import_start": 0,
    "import_end": 0,
    "summary": 0,
}

for line in lines:
    stripped = line.strip()
    indent = line[: len(line) - len(line.lstrip())]

    if stripped.startswith("async fn "):
        function = stripped.split("async fn ", 1)[1].split("(", 1)[0]

    if function == "sync_pruning_point_utxoset" and stripped == "let mut multiset = MuHash::new();":
        out.append(line)
        out.append(f"{indent}let processing_started = metrics_enabled().then(Instant::now);")
        out.append(f"{indent}let mut processing_chunks = 0u64;")
        out.append(f"{indent}let mut processing_utxos = 0u64;")
        out.append(f"{indent}let mut append_time = Duration::ZERO;")
        counts["stage"] += 1
        continue

    if function == "sync_pruning_point_utxoset" and stripped == "while let Some(chunk) = chunk_stream.next().await? {":
        out.append(line)
        child = indent + "    "
        out.append(f"{child}if metrics_enabled() {{")
        out.append(f"{child}    processing_chunks = processing_chunks.saturating_add(1);")
        out.append(f"{child}    processing_utxos = processing_utxos.saturating_add(chunk.len() as u64);")
        out.append(f"{child}}}")
        counts["chunk"] += 1
        continue

    if function == "sync_pruning_point_utxoset" and stripped == "multiset = consensus":
        out.append(f"{indent}let append_started = metrics_enabled().then(Instant::now);")
        out.append(line)
        inside_append = True
        counts["append_start"] += 1
        continue

    if function == "sync_pruning_point_utxoset" and inside_append and stripped == ".await;":
        out.append(line)
        out.append(f"{indent}if let Some(append_started) = append_started {{")
        out.append(f"{indent}    append_time = append_time.saturating_add(append_started.elapsed());")
        out.append(f"{indent}}}")
        inside_append = False
        counts["append_end"] += 1
        continue

    if function == "sync_pruning_point_utxoset" and stripped == "consensus.clone().spawn_blocking(move |c| c.import_pruning_point_utxo_set(pruning_point, multiset)).await?;":
        out.append(f"{indent}let import_started = metrics_enabled().then(Instant::now);")
        out.append(line)
        out.append(f"{indent}let import_time = import_started.map(|started| started.elapsed()).unwrap_or(Duration::ZERO);")
        counts["import_start"] += 1
        counts["import_end"] += 1
        out.append(f"{indent}if metrics_enabled() {{")
        out.append(f"{indent}    let elapsed = processing_started.expect(\"metrics start is present when metrics are enabled\").elapsed();")
        out.append(f"{indent}    let elapsed_seconds = elapsed.as_secs_f64();")
        out.append(f"{indent}    let processing_time = append_time.saturating_add(import_time);")
        out.append(f"{indent}    let processing_ratio =")
        out.append(f"{indent}        if elapsed_seconds == 0.0 {{ 0.0 }} else {{ (processing_time.as_secs_f64() / elapsed_seconds).clamp(0.0, 1.0) }};")
        out.append(f"{indent}    let utxos_per_second =")
        out.append(f"{indent}        if elapsed_seconds == 0.0 {{ 0.0 }} else {{ processing_utxos as f64 / elapsed_seconds }};")
        out.append(f"{indent}    let average_append_ms =")
        out.append(f"{indent}        if processing_chunks == 0 {{ 0.0 }} else {{ append_time.as_secs_f64() * 1000.0 / processing_chunks as f64 }};")
        out.append(f"{indent}    info!(")
        out.append(f"{indent}        \"IBD-V2-METRICS: stage=utxo-processing complete=true chunks={{}} utxos={{}} elapsed={{:.3}}s rate={{:.2}} utxos/s append={{:.3}}s avg_append={{:.3}}ms/chunk final_import={{:.3}}s processing_pct={{:.1}}%\",")
        out.append(f"{indent}        processing_chunks,")
        out.append(f"{indent}        processing_utxos,")
        out.append(f"{indent}        elapsed_seconds,")
        out.append(f"{indent}        utxos_per_second,")
        out.append(f"{indent}        append_time.as_secs_f64(),")
        out.append(f"{indent}        average_append_ms,")
        out.append(f"{indent}        import_time.as_secs_f64(),")
        out.append(f"{indent}        processing_ratio * 100.0")
        out.append(f"{indent}    );")
        out.append(f"{indent}}}")
        counts["summary"] += 1
        continue

    out.append(line)

expected = {
    "stage": 1,
    "chunk": 1,
    "append_start": 1,
    "append_end": 1,
    "import_start": 1,
    "import_end": 1,
    "summary": 1,
}
if counts != expected:
    raise SystemExit(f"patch anchors mismatch: {counts}")

path.write_text("\n".join(out) + "\n", encoding="utf-8")
