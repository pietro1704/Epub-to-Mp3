# CLI Conversion Performance Remediation Plan

> **For Hermes:** Use the `subagent-driven-development` skill to implement this plan task-by-task, with strict TDD and a spec-compliance review after each task.

**Goal:** Reduce CLI conversion wall time and time-to-first-audio without sacrificing chapter completeness, resume safety, Edge fallback behavior, or the shared CLI/web cache contract.

**Architecture:** First add request-level observability and a reproducible isolated benchmark. Then tune the existing Edge transport, concurrency controller, segmentation, preparation pipeline, validation, and stream-cache lifecycle one behavior at a time behind reversible flags. Keep the current behavior as the rollback path until each change passes unit tests, the full suite, and a live A/B benchmark.

**Tech Stack:** Python 3.12, asyncio, Edge-TTS/WebSocket, FastAPI shared backend, pytest, mise-managed commands, JSONL runtime metrics, MP3/Mutagen validation.

---

## Scope and guardrails

This plan covers the CLI conversion findings documented in:

`docs/cli-conversion-performance-analysis-2026-07-23.md`

It does not change the iOS Simulator policy, `ai-jail`, CoreSimulator, SwiftUI, or the active conversion. The current conversion must be allowed to finish before its final log is used as the baseline.

Rules for implementation:

- Do not use the live `The Lord of the Rings` cache as a test fixture.
- Do not run live Edge requests from the pytest suite.
- Do not increase Edge concurrency or segment duration globally before the benchmark gate.
- Preserve the current fallback chain and resume semantics.
- Mirror changes that affect shared Edge behavior, cache layout, or server observability in the web/API path.
- Every production-code task follows RED → GREEN → REFACTOR.
- Do not use `importlib.reload()` in tests.
- Do not commit, push, reset, pull, or rewrite unrelated working-tree changes.
- Use `mise run ...` / `mise exec ...` for project commands.

## Current evidence to preserve as baseline

The live run measured approximately:

- 226.6 weighted characters/s per completed chapter;
- 1,156,904 synthesized characters across 35 completed chapter events;
- 962 recent chunks for approximately 1,218,626 characters;
- 1,266.8 average characters per chunk;
- average chapter overlap 3.73, peak 8;
- converter CPU approximately 1–3% and RSS approximately 30–36 MiB;
- 4 physical CPUs, 8 GiB RAM, approximately 1.58 GiB available during the profile;
- approximately 10 minutes between process start and the first `chapter_perf` event;
- repeated `pipeline_enabled` events with `chapters: 1`;
- ambiguous `chapter_index: 1` values across different hierarchical chapters.

These numbers are observations, not new targets. The first implementation task must capture the final run totals because the active run was still in progress.

## Feature-flag strategy

Add or reuse explicit switches so every behavior change can be disabled independently:

- `CLI_PERF_SEGMENT_METRICS=1`
- `CLI_BOUNDED_PREPARE=0`
- `EDGE_ADAPTIVE_SEGMENT_SECONDS=0`
- `EDGE_DYNAMIC_PARALLELISM=0`
- `EDGE_VALIDATE_SEGMENTS=1`
- `STREAM_CHUNK_CLEANUP=0`

Defaults remain equivalent to the current behavior until the corresponding benchmark gate is passed. The final rollout task may change defaults only for features that meet the acceptance criteria below.

---

## Phase 0 — Close the baseline and create a safe benchmark

### Task 0.1: Capture the final active-run baseline

**Objective:** Produce a final, immutable comparison record without changing the running conversion.

**Files:**
- Read: `.logs/events.jsonl`
- Read: `.logs/conversions.jsonl`
- Read: `.cache/The Lord of the Rings/_runtime_metrics.jsonl`
- Read: `.cache/The Lord of the Rings/metrics-summary.json` when present
- Create: `docs/cli-conversion-performance-baseline-2026-07-23.md`

**Steps:**

1. Wait until PID `8310` exits; do not kill or signal it.
2. Parse final chapter count, success/failure count, retries, engine switches, total chars, wall time, and cache/output bytes.
3. Record the exact effective environment values relevant to speed, excluding secrets.
4. Record missing telemetry fields explicitly instead of inferring them.
5. Verify that the baseline document is read back and contains no credentials or source URLs with embedded tokens.

**Verification:**

```bash
mise run test
```

For this documentation-only task, the focused verification is a JSONL parse plus a read-back of the new Markdown file. Do not run another live conversion.

**Acceptance:** The final baseline distinguishes measured values, inferred causes, and unknowns. It does not modify `.cache`, `output`, or the active conversion.

### Task 0.2: Add an isolated benchmark fixture and runner

**Objective:** Make repeated performance comparisons possible without touching the user’s active cache.

**Files:**
- Create: `scripts/benchmark_cli_performance.py`
- Create: `python_app/tests/test_cli_performance_benchmark.py`
- Read/verify: `python_app/src/paths.py`, `python_app/src/config.py`, `mise.toml`

**Design:**

- Accept a list of cached text chapters or a small EPUB fixture.
- Run only against a temporary `PERSISTENT_ROOT`, `CACHE_DIR`, and `OUTPUT_DIR`.
- Support `--dry-run`, `--engine edge`, explicit `--chapter-parallel`, explicit segment duration, and a run manifest.
- Never invoke live Edge unless the operator explicitly passes `--live-edge`.
- Emit one JSON result per profile with wall time, chars/s, request count, failures, retries, peak RSS, peak available RAM, cache bytes, and output hash.
- Make the result parser testable without network access.

**TDD:**

1. Write parser tests for complete, failed, and interrupted benchmark manifests.
2. Run the focused test and verify the expected failure.
3. Implement the smallest parser/manifest writer.
4. Run the focused test again.
5. Add the opt-in runner only after the parser is green.

**Acceptance:** A benchmark can run against an isolated temporary root and cannot accidentally reuse `.cache/The Lord of the Rings`.

---

## Phase 1 — Make the bottleneck measurable

### Task 1.1: Preserve stable chapter identity across parallel workers

**Objective:** Stop logging every singleton worker as chapter 1 and preserve both source identity and display label.

**Files:**
- Modify: `python_app/src/converter.py:3140-3165, 3778-3882, 5867-5895`
- Modify: `python_app/src/session_logger.py:155-180`
- Modify: `python_app/src/_metrics_report_mixin.py`
- Test: `python_app/tests/test_converter.py`
- Create: `python_app/tests/test_session_logger.py`

**Design:**

Pass a stable identity object or explicit fields through `_convert_chapters_parallel()` into `_convert_chapters_sequential()`:

- `source_chapter_index`: original EPUB index;
- `display_chapter_label`: hierarchical label such as `10.1.3`;
- `worker_local_index`: local loop index;
- `segment_index`: chunk position.

Update `chapter_perf`, `chapter_error`, runtime metrics, manifests, and dashboards to use the stable identity. Keep the existing display filename behavior unchanged.

**Tests:**

- Parallel singleton workers preserve distinct source indices and labels.
- Existing output ordering remains deterministic.
- JSONL events remain backward-compatible for readers that only use `chapter_index`.
- A chapter with a hierarchical label and a chapter with a numeric label do not collide.

**Acceptance:** No distinct completed chapters in a new benchmark share the same identity tuple.

### Task 1.2: Instrument the actual Edge request lifecycle

**Objective:** Split chapter time into queue wait, Edge synthesis, retries, file write, and validation time.

**Files:**
- Modify: `python_app/src/tts/edge_engine.py:2160-2534`
- Modify: `python_app/src/_edge_throttle_mixin.py:429-475, 616-650`
- Modify: `python_app/src/_metrics_report_mixin.py:37-120, 125-210`
- Test: `python_app/tests/test_edge_engine.py`
- Test: `python_app/tests/test_converter.py`

**Design:**

Reuse the existing monotonic timestamps already present in `_synthesize_segment()`:

- `queue_wait_ms`: from `waiting_start` to semaphore acquisition;
- `request_ms`: from stream start to successful/failed completion;
- `retry_count`: number of recreated communicators;
- `received_chunks`: audio/event chunks from Edge;
- `write_ms`: time writing the segment file;
- `validation_ms`: time spent in segment validation;
- `active_requests`: effective global/instance slots at acquisition;
- `status` and normalized `error_category`.

Emit compact records through the existing `_append_segment_metric()` path. Do not include full text, credentials, audio bytes, or raw connection details. Keep logging failure-safe and non-blocking enough that telemetry cannot become the bottleneck.

Add aggregation fields to the existing metrics summary/CSV rather than introducing a second dashboard format.

**Tests:**

- Success emits one complete metric record.
- Timeout, rate limit, no-audio, cancellation, and retry emit the correct status/count.
- Queue wait is zero or positive and request duration excludes queue wait.
- Metrics failure never fails synthesis.
- Summary aggregation computes p50/p95 without crashing on a one-record or empty input.

**Acceptance:** A benchmark report can identify whether a slow chapter is waiting for a slot, waiting for Edge, retrying, writing, or validating.

### Task 1.3: Record the effective runtime profile once

**Objective:** Make every run self-describing so concurrency and profile decisions can be compared later.

**Files:**
- Modify: `python_app/src/converter.py:2101-2142`
- Modify: `python_app/src/hardware_detector.py:555-691`
- Modify: `python_app/src/_metrics_report_mixin.py`
- Test: `python_app/tests/test_converter.py`
- Test: `python_app/tests/test_main.py`

**Fields:**

- CPU physical/logical counts;
- total and available RAM;
- network tier and probe latency summary;
- `MAX_PERFORMANCE` and all effective Edge/chapter limits;
- thermal/power cap;
- whether any cap came from RAM, network, thermal, or explicit environment override.

**Acceptance:** The first runtime record exposes the values actually used, not only dataclass defaults or requested values.

---

## Phase 2 — Establish safe concurrency control

### Task 2.1: Add a deterministic resource-pressure policy

**Objective:** Prevent turbo mode from selecting an unsafe ceiling when the 8 GiB Mac has little available RAM, while preserving aggressive behavior when resources are healthy.

**Files:**
- Modify: `python_app/src/hardware_detector.py:585-648`
- Modify: `python_app/src/_edge_throttle_mixin.py:520-566`
- Modify: `python_app/src/config.py:64-75` only if new operator settings are required
- Test: `python_app/tests/test_converter.py`
- Create: `python_app/tests/test_hardware_detector.py`

**Design:**

Introduce explicit, documented thresholds for available RAM and a reason-coded ceiling. The controller must:

- clamp initial chapter slots when available RAM is below the safe threshold;
- reduce slots after consecutive pressure observations;
- grow only after consecutive stable observations;
- keep Edge request concurrency separate from chapter concurrency;
- honor explicit operator overrides but still report that the override bypassed the guard;
- never increase the ceiling merely because CPU is idle when RAM is under pressure.

Do not use a single instantaneous sample to oscillate the controller. Reuse the existing streak/cooldown mechanism and add hysteresis tests.

**Acceptance:** With simulated 8 GiB/1 GiB available, the controller selects a bounded starting ceiling; with healthy RAM and low CPU it can recover; all transitions have a reason in metrics.

### Task 2.2: Benchmark chapter slots before changing defaults

**Objective:** Determine whether 4, 6, or 8 chapter slots is fastest and reliable on the actual Mac/network.

**Files:**
- Use: `scripts/benchmark_cli_performance.py`
- Extend: `python_app/tests/test_cli_performance_benchmark.py`
- Read: `python_app/tests/test_edge_optimization_benchmark.py`

**Profiles:**

- chapter slots: 4, 6, 8;
- Edge request cap: current effective cap, then one controlled higher profile only if the service remains healthy;
- same voice, same text set, same isolated output root;
- one warm-up run excluded from the measured result;
- no cache reuse between profiles.

**Acceptance:** Select the highest throughput profile whose failure/retry rate is not worse than baseline and whose peak memory leaves the defined safety margin. If no profile beats baseline by at least 10%, keep the current ceiling and document why.

### Task 2.3: Make adaptive concurrency react to Edge signals

**Objective:** Use actual p95 request latency and Edge errors, not only CPU/RAM, to avoid both underutilization and rate-limit storms.

**Files:**
- Modify: `python_app/src/_edge_throttle_mixin.py`
- Modify: `python_app/src/tts/edge_engine.py`
- Modify: `python_app/src/engine_pool.py` if slot updates require a shared API
- Test: `python_app/tests/test_converter.py`
- Test: `python_app/tests/test_edge_transport_swap.py`

**Design:**

- Add a rolling window of successful request latencies and error categories.
- Increase one slot only after a stable streak and acceptable p95.
- Decrease immediately on 403/rate-limit, repeated timeout, or no-audio service failure.
- Keep a cooldown to prevent oscillation.
- Record every adjustment with old value, new value, and reason.
- Do not raise the hard Edge cap above the existing safe cap without an explicit benchmark result.

**Acceptance:** Simulated rate limits reduce concurrency before the next burst; stable low-latency requests recover gradually; the full fallback chain remains unchanged.

---

## Phase 3 — Reduce request overhead safely

### Task 3.1: Add adaptive segment-duration policy behind a flag

**Objective:** Reduce the approximately 1,267-character average request size without making truncation/retry behavior worse.

**Files:**
- Modify: `python_app/src/config.py:64-75`
- Modify: `python_app/src/tts/edge_engine.py:1738-1810, 2154-2158`
- Modify: `python_app/src/_edge_throttle_mixin.py:598-615`
- Test: `python_app/tests/test_edge_engine.py`
- Create: `python_app/tests/test_edge_segment_policy.py`

**Design:**

Keep the current 85-second behavior as the initial safe value. At chapter boundaries only:

1. start at 85–120 seconds depending on the measured profile;
2. increase toward 120–180 seconds after a stable success streak;
3. lower the target after timeout, no-audio, truncation, or p95 regression;
4. never re-segment an already-resumed chapter with a different policy;
5. persist the policy state with the runtime tuning state, not in the book’s content cache;
6. keep the existing segment split and retry fallback as the final safety path.

The policy must be based on actual completed requests, not the network connect probe alone.

**Tests:**

- Stable successes promote the target only at a chapter boundary.
- A failure demotes the target and does not discard valid prior chunks.
- Resumed chunks keep their original indices and remain compatible.
- Segment duration remains within the configured hard maximum.
- Full text reconstruction remains unchanged.

**Acceptance:** The benchmark reduces requests per million characters by at least 20% on clean long chapters, with no increase in missing/truncated audio or retry rate.

### Task 3.2: Evaluate transport reuse as a separate spike

**Objective:** Determine whether connection setup/teardown is materially contributing to request latency before attempting a risky transport rewrite.

**Files:**
- Read/experiment: `python_app/src/tts/edge_engine.py:2216-2259, 2497-2505`
- Use: `scripts/benchmark_cli_performance.py`
- Create if promoted: `python_app/tests/test_edge_transport_pool.py`

**Rules:**

- Time-box the spike.
- Do not merge a persistent WebSocket/session pool based only on theoretical savings.
- Compare request latency and error rate against the current communicator lifecycle.
- Preserve connector cleanup and cancellation semantics.

**Acceptance:** Either produce measured evidence for a safe reuse design or record `INVALIDATED` and leave the current transport unchanged.

---

## Phase 4 — Remove the preparation barrier

### Task 4.1: Specify a bounded prepared-chapter handoff

**Objective:** Allow synthesis to start after the first few chapters are prepared instead of waiting for all text files.

**Files:**
- Modify: `python_app/src/converter.py:2976-3053, 3140-3165, 3778-3936`
- Create if needed: `python_app/src/_chapter_pipeline.py`
- Test: `python_app/tests/test_converter.py`
- Create: `python_app/tests/test_converter_bounded_prepare.py`

**Design:**

Use a bounded queue of prepared payloads keyed by stable chapter identity. Preserve the existing cache validation rules, but separate them from full text generation:

- perform lightweight cache/index discovery first;
- prepare at most `stage_pipeline_depth` or an explicit bounded number of chapters ahead;
- submit a chapter task as soon as its payload is ready;
- allow later preparation to continue in `asyncio.to_thread()` workers;
- pass the prepared payload into the singleton synthesis worker so it does not resolve it a second time;
- retain deterministic output ordering and progress indices;
- cancel and drain producer tasks on conversion failure, hard timeout, or user cancellation.

Do not mutate `Chapter` objects with hidden payload fields unless the existing model already supports that contract; prefer an explicit prepared-payload structure.

**Tests:**

- First chapter synthesis starts before all chapters are prepared.
- Preparation never exceeds the configured queue bound.
- Each payload is prepared at most once.
- A preparation exception is reported against the correct stable chapter identity.
- Cancellation closes the producer and leaves resumable state intact.
- Cache-only conversion still skips synthesis.

**Acceptance:** Time-to-first-audio is at least 50% lower than baseline on the representative fixture, without increasing total wall time or duplicate preparation work.

### Task 4.2: Remove misleading singleton pipeline metrics

**Objective:** Make `pipeline_enabled` describe the global queue instead of each one-chapter worker.

**Files:**
- Modify: `python_app/src/converter.py:3778-3824`
- Modify: `python_app/src/_metrics_report_mixin.py`
- Test: `python_app/tests/test_converter_bounded_prepare.py`

**Acceptance:** A parallel run emits one preparation-pipeline initialization event with queue depth and total pending chapters, plus per-chapter prepare events with stable identities. It must not emit a false `chapters: 1` global summary for every worker.

---

## Phase 5 — Move validation to the highest-value boundary

### Task 5.1: Add explicit segment-validation modes

**Objective:** Avoid repeating expensive duration parsing for every successful segment when chapter-level validation is sufficient.

**Files:**
- Modify: `python_app/src/config.py:47-60`
- Modify: `python_app/src/tts/edge_engine.py:1503-1547, 1613-1681`
- Modify: `python_app/src/audio_validator.py` only if a lightweight MP3 check is needed
- Test: `python_app/tests/test_edge_engine.py`
- Create: `python_app/tests/test_audio_validation_modes.py`

**Design:**

Add an explicit mode such as `segment_validation = full|fast|off`, with `full` retained initially. The fast mode may check file existence, minimum size, and basic MP3 readability while deferring duration checks to the completed chapter. Deep validation remains available for failures and final output.

Do not remove `SynthesisTracker` completeness records; they are needed for selective recovery. Only avoid repeated duration parsing when the mode allows it.

**Tests:**

- Full mode preserves current validation behavior.
- Fast mode does not call duration parsing for every successful chunk.
- Failed/short/corrupt segments still enter the retry path.
- Chapter-level duration validation still catches truncation.
- Defaults remain backward-compatible until the benchmark gate.

**Acceptance:** Validation time is separately visible in metrics and the fast mode has no completeness regression on the representative fixture.

### Task 5.2: Benchmark validation cost before changing its default

**Objective:** Quantify whether segment validation is material after Edge request overhead is reduced.

**Files:**
- Use: `scripts/benchmark_cli_performance.py`
- Extend: `python_app/tests/test_cli_performance_benchmark.py`

**Profiles:**

- full segment validation;
- fast segment validation plus chapter validation;
- same Edge settings and same text set.

**Acceptance:** Change the default only if fast validation saves at least 5% wall time or a measurable validation budget while preserving all output integrity checks.

---

## Phase 6 — Reclaim completed stream-cache space safely

### Task 6.1: Add completion-aware stream cleanup

**Objective:** Remove or compact chunk files only after the final chapter audio is verified and resumability is no longer needed.

**Files:**
- Inspect/modify: `python_app/src/cache_manager.py`
- Inspect/modify: `python_app/src/_output_file_mixin.py`
- Inspect/modify: `python_app/src/paths.py`
- Mirror if shared behavior requires it: `python_app/server.py`, `python_app/src/_server_job_helpers.py`, `python_app/src/_server_audio_helpers.py`
- Test: `python_app/tests/test_cache_manager.py` (create if absent)
- Create: `python_app/tests/test_stream_chunk_cleanup.py`

**Design:**

- Keep chunks for active, failed, cancelled, or resumable chapters.
- Delete/compact chunks only after final MP3 existence, size/integrity, manifest completion, and final hash are verified.
- Never delete chunks belonging to an active job.
- Make cleanup idempotent and crash-safe.
- Record bytes before/after and number of removed files.
- Keep a retention override for operators who need post-run forensic recovery.

**Tests:**

- Active chapters are never cleaned.
- Failed chapters retain chunks.
- Completed and validated chapters are cleaned exactly once.
- Cleanup interruption can resume safely.
- A second cleanup call is a no-op.
- CLI and web/shared cleanup do not diverge.

**Acceptance:** A completed benchmark run reduces stream-cache bytes without changing final MP3 hashes or resume behavior.

### Task 6.2: Add cache-size and cleanup metrics to the final report

**Objective:** Make storage overhead visible alongside speed.

**Files:**
- Modify: `python_app/src/_metrics_report_mixin.py`
- Modify: `python_app/src/cache_manager.py`
- Test: `python_app/tests/test_cache_metrics.py`

**Acceptance:** The final summary reports cache bytes before/after, active protected bytes, deleted bytes, and cleanup duration.

---

## Phase 7 — Roll out only validated improvements

### Task 7.1: Run the full benchmark matrix

**Objective:** Select defaults using evidence rather than intuition.

**Matrix:**

- chapter concurrency: 4, 6, 8;
- segment target: current 85, 120, 180 s;
- validation: full vs fast;
- bounded preparation: disabled vs enabled;
- stream cleanup: disabled vs enabled after completion.

Do not run every Cartesian combination if the first stage rules out a profile; keep the matrix time-boxed and record exclusions.

**Acceptance thresholds:**

- total wall time improves by at least 15% versus baseline, or the individual change is not promoted;
- time-to-first-audio improves by at least 50% when bounded preparation is enabled;
- requests per million characters improve by at least 20% when adaptive segmentation is enabled;
- no increase in missing/truncated chapters;
- retry/error rate is no worse than baseline;
- no sustained low-memory condition, swap pressure, or OOM;
- final MP3 hashes and chapter ordering remain correct;
- cache cleanup meets its retention contract.

### Task 7.2: Run project quality gates

**Objective:** Verify that performance changes do not regress the dual conversion paths or existing functionality.

**Commands:**

```bash
mise run test
pytest -v --tb=short python_app/tests/test_edge_engine.py
pytest -v --tb=short python_app/tests/test_converter.py
pytest -v --tb=short python_app/tests/test_cli_performance_benchmark.py
```

If code was changed under both CLI and server paths, run the relevant server/API tests too. Do not run the iOS Simulator locally on this Mac.

**Acceptance:** Full suite passes, targeted tests pass, benchmark report is stored outside the live cache, and no unrelated files are modified.

### Task 7.3: Promote defaults with a rollback note

**Objective:** Enable only the validated improvements and preserve a one-command rollback.

**Files:**
- Modify only validated defaults in `python_app/src/config.py`, `python_app/src/hardware_detector.py`, and/or `python_app/src/tts/edge_engine.py`
- Update: `CLAUDE.md` performance settings if defaults change
- Update: `docs/cli-conversion-performance-analysis-2026-07-23.md` with before/after results
- Test: all affected tests

**Rollback:**

Document the exact environment overrides that restore the previous behavior:

```bash
CLI_BOUNDED_PREPARE=0 \
EDGE_ADAPTIVE_SEGMENT_SECONDS=0 \
EDGE_DYNAMIC_PARALLELISM=0 \
EDGE_VALIDATE_SEGMENTS=1 \
STREAM_CHUNK_CLEANUP=0
```

Do not delete old code paths until at least one real-book conversion and the full suite pass with the new defaults.

---

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Edge 403/rate limiting after concurrency increase | Rolling p95/error controller, hard cap, benchmark gate, immediate rollback flag |
| Larger segments produce truncation or no-audio | Increase only at chapter boundaries, preserve safe subdivision/retry, validate duration |
| Bounded preparation creates duplicate work | Explicit prepared-payload handoff and test asserting one preparation per chapter |
| Low RAM on the 8 GiB Mac | Available-RAM hysteresis, protected floor, reason-coded slot reductions |
| Validation shortcut misses corruption | Chapter-level validation remains mandatory; deep mode on suspicious output |
| Cleanup deletes resumable data | Active/failed protection, completion marker, final hash validation, idempotent cleanup |
| CLI/web behavior diverges | Shared metric schema and explicit server/cache contract tests |
| Metrics slow down conversion | Compact JSONL, no text/audio payloads, failure-safe writes, benchmark telemetry overhead |
| Existing local working-tree changes are overwritten | Restrict edits to planned files and inspect `git diff --name-only` before every commit |

## Final deliverables

1. Final active-run baseline document.
2. Isolated benchmark runner and parser tests.
3. Stable chapter identity and request-level metrics.
4. Resource-aware adaptive concurrency.
5. Validated adaptive segment sizing.
6. Bounded preparation pipeline with no duplicate work.
7. Configurable fast/full validation boundary.
8. Completion-aware stream cleanup and cache metrics.
9. Before/after benchmark report.
10. Updated performance analysis with measured results and rollback instructions.

Implementation must stop after each phase if its acceptance criteria fail; do not bundle all changes into one unmeasured optimization commit.
