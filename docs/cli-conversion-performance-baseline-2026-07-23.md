# CLI Conversion Performance Baseline — 2026-07-23

## Scope

This is the final read-only baseline for the CLI conversion that was running as PID `8310` and was stopped by the operator. No process signal was sent by the assistant, and no cache or output files were modified while closing this record.

The invocation observed before termination was:

```text
.venv/bin/python python_app/convert <local Lord of the Rings EPUB> --engine auto --verbose
```

The source path is intentionally not repeated here. No credential-bearing URL or token was present in this document.

## Measured run

Source: `.cache/The Lord of the Rings/_runtime_metrics.jsonl`, parsed as JSONL with zero invalid records.

| Metric | Measured value |
|---|---:|
| Runtime start | 2026-07-23 17:30:03.654 UTC |
| Last runtime event | 2026-07-23 18:12:26.957 UTC |
| Wall-clock span represented by runtime events | 2,543.303 s (42m 23.3s) |
| Completed chapter events | 40 |
| Successful chapter events | 40 |
| Failed chapter events | 0 |
| Characters synthesized in completed events | 1,403,473 |
| Sum of completed synthesis elapsed time | 6,273.970 s |
| Weighted synthesis throughput | 223.697 chars/s |
| Average characters per completed event | 35,086.8 |
| Engine observed | Edge only |
| Retry attempts in runtime records | Attempt 1 only |
| Final runtime event | `pipeline_stage_start`, stage `synthesize`, local chapter `1` |

The first completed chapter event was recorded 1.606 s after the first runtime event. The final runtime event has no corresponding completion record, so at least one synthesis operation was in flight when the process stopped.

The run is therefore **interrupted/partial**, not a successful full-book conversion. The records do not contain the total source-chapter count, so completion percentage cannot be inferred safely.

## Cache and output snapshot after stop

These are read-only byte counts taken after the process stopped:

| Location | Files | Bytes |
|---|---:|---:|
| `.cache/The Lord of the Rings/` | 1,483 | 1,132,438,026 |
| `output/` (entire shared output root) | 15 | 715,652 |

No file matching `*Lord*` was found directly under `output/` at snapshot time. The output-root count includes pre-existing files and is not attributed to this interrupted run.

`metrics-summary.json` was not present in the book cache at snapshot time.

## Identity and telemetry findings

The runtime records expose `chapter` values only in the range `1..10`, while the matching `.logs/events.jsonl` records for the same wall-clock window also use only the local numeric values `1..10`. Hierarchical chapter labels and a stable original EPUB index are not present in these records. This confirms the plan's identity-collision finding: the current telemetry cannot distinguish all completed chapters by `chapter_index` alone.

The runtime file emitted 41 `pipeline_enabled` events, all reporting `chapters: 1`, alongside 82 `pipeline_stage_start` and 81 `pipeline_stage_done` events. This supports the plan's finding that the pipeline metric currently describes singleton workers rather than one global preparation queue.

## Effective configuration

The following values were requested or observed from the command/configuration context:

- CLI mode: `auto`
- Verbose logging: enabled
- Runtime engine observed: Edge
- Runtime environment variables affecting concurrency, segment duration, validation, and preparation: **not captured by the process telemetry**
- Exact effective CPU/RAM/network/thermal profile: **not captured**
- Exact source total and final completion state: **unknown because the run was interrupted**

The configured defaults in source files must not be treated as the effective values for this historical process. Phase 1 of the implementation will add a one-time runtime profile event so future baselines can distinguish requested, defaulted, and operator-overridden values.

## Acceptance status

- Final baseline is immutable documentation of an interrupted run: **complete**.
- Active conversion was not restarted or modified by this baseline task: **verified**.
- Cache/output were not modified by this baseline task: **verified by read-only workflow**.
- Full-book success, missing chapters, final MP3 hashes, and resume safety: **not established; requires a new isolated or explicitly authorized real-book run**.
