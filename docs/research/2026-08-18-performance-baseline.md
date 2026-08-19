# End-to-end performance baseline — 2026-08-18

## Decision

The repository has enough evidence to baseline **conversion throughput**, but
not enough to claim a user-visible end-to-end baseline for the Apple, web, or
Flutter clients. The first implementation slice must establish one shared
latency contract and collect it before changing production behavior.

`Warm book open`, `Cold book open`, `Progressive playback`, and the
`Performance program` are defined in [CONTEXT.md](../../CONTEXT.md). The
agreed budgets are warm open at or below 200 ms and cold usable/open-audio
startup at or below one second. No current measurement proves either budget.

## What is already measured

| Surface / run | Evidence | Measured result | What it proves | What it does not prove |
|---|---|---:|---|---|
| CLI, scanned-PDF conversion | Read-only local runtime log for the Odisseia scan run; one `runtime_profile` and 389 `chapter_complete` events | 704,175 chars; 389/389 successful Edge chapters; 7,326.906 s wall span; 14,304.834 s summed synthesis; 49.226 weighted chars/s | Current real conversion behavior for this scanned-PDF corpus and host configuration | EPUB throughput, server/API throughput, request-to-audible latency, or a general Edge SLA |
| Same CLI run, earliest completed chapter | `runtime_profile.ts=1787068517.384`; first `chapter_complete.ts=1787068525.649` | 8.265 s to the first **completed chapter** | A concrete upper bound for this CLI run's first complete chapter | First audible progressive audio: the CLI completion event is not an Apple player-audibility event |
| Historical CLI, interrupted The Lord of the Rings run | [CLI conversion baseline](../cli-conversion-performance-baseline-2026-07-23.md) | 40 successful completed events; 1,403,473 chars; 223.697 weighted chars/s; first completion 1.606 s after first runtime event | A useful historical Edge comparison point | A completed-book result or a current comparable run; the process was interrupted |
| Synthetic backend CI harness, three runs made during this research | [`run_ci_speed_benchmark.py`](../../python_app/tests/run_ci_speed_benchmark.py) with a 250,000 chars/s mock and isolated `/tmp` reports | 19,165.5 / 20,166.3 / 20,777.0 chars/s; mean 20,036.3 chars/s | The local converter path plus temporary-file workflow remains runnable and has modest run-to-run variation | TTS/network speed: the engine is deliberately synthetic ([source](../../python_app/src/ci_speed_benchmark.py#L30-L60)) |
| Apple reader, PDF normalization, and audio stream | Cache/stream implementation exists in [book open](../../ios/EpubToMp3/EpubToMp3/Features/Reader/Views/BookOpenScreenController.swift#L968-L1051), [PDF normalization cache](../../ios/EpubToMp3/EpubToMp3/Features/Documents/Services/PdfTextExtractor.swift#L372-L405), and [first streamed segment queueing](../../ios/EpubToMp3/EpubToMp3/Features/Playback/Services/AudioPlayer.swift#L1966-L2007) | No latency samples | The intended warm paths and progressive-audio path exist | Time from gesture to text, controls, visual PDF page, seek completion, or audible audio |
| Web and Flutter | Web exposes engine-throughput telemetry through [`/api/telemetry`](../../python_app/src/routes_telemetry.py#L28-L87); the web test command is Vitest only ([package scripts](../../web/package.json)); Flutter has `flutter_test` but no performance/integration dependency ([pubspec](../../flutter_app/pubspec.yaml)) | No user-flow latency samples | Conversion throughput is displayable in the web UI | Client startup, reader readiness, first audio, seek, frame pacing, and energy |

### Real scanned-PDF profile

The local run was explicitly capped by available RAM: 8 logical / 4 physical
CPUs, 8 GiB RAM, 2.101 GiB available. It used `max_performance=true`, two
effective chapter workers, seven Edge segment slots, 15,000-character chunks,
and 300-second segments. It is therefore a valid **corpus/profile-specific**
baseline, not a default-product claim.

The backend already records request, queue, write, retry, validation, and
p50/p95 segment dimensions in
[`_metrics_report_mixin.py`](../../python_app/src/_metrics_report_mixin.py#L340-L466).
The persistent regression floor is only an engine-throughput floor (Edge 120
chars/s; Piper 90 chars/s), not a client-latency budget:
[`benchmarks/baseline.json`](../../benchmarks/baseline.json).

## Existing measurement machinery

- [`scripts/benchmark_cli_performance.py`](../../scripts/benchmark_cli_performance.py#L548-L701)
  enforces isolated cache/output roots and requires `--live-edge` before a
  real network request. Its current input validator accepts `.txt` and `.epub`,
  not PDF, so it cannot provide a controlled scanned-PDF benchmark yet.
- [`scripts/real_engine_benchmark.py`](../../scripts/real_engine_benchmark.py)
  and [`scripts/benchmark_engines_full.py`](../../scripts/benchmark_engines_full.py)
  cover real TTS profiles; [`scripts/benchmark_feature_ab.py`](../../scripts/benchmark_feature_ab.py)
  covers the pipeline/worker A/B case.
- [`nightly-benchmark.yml`](../../.github/workflows/nightly-benchmark.yml) and
  [`feature-ab-regression.yml`](../../.github/workflows/feature-ab-regression.yml)
  gate backend benchmark scenarios. The CI speed benchmark is intentionally
  synthetic, not a production throughput observation.
- [`LocalFulltextCache`](../../ios/EpubToMp3/EpubToMp3/Features/Offline/Services/LocalFulltextCache.swift)
  retains the two most recent reader payloads; iOS and macOS pre-warm them
  before a reader transition. The actual reader open path still contains no
  timing sample. PDF warm opens instead reuse the normalized derivative cache
  when a scanned two-up source needs one.

## Reproducible commands

These commands keep benchmark artifacts outside the repository cache/output
roots. Replace the representative input only for the live network run.

```bash
# Safe: deterministic mock, no Edge request or user cache/output mutation.
PYTHONPATH=python_app .venv/bin/python python_app/tests/run_ci_speed_benchmark.py \
  --cps 250000 \
  --output /tmp/epub2mp3-ci-speed.json \
  --baseline-file /tmp/epub2mp3-ci-speed-baseline.json \
  --period-hours 0

# Safe: validates the isolated manifest and input shape without conversion.
python scripts/benchmark_cli_performance.py /path/to/representative.epub \
  --dry-run \
  --root /tmp/epub2mp3-cli-benchmark \
  --manifest /tmp/epub2mp3-cli-benchmark.json

# Deliberate external/network measurement: record corpus hash, voice, network,
# and effective runtime profile with the output before running this.
python scripts/benchmark_cli_performance.py /path/to/representative.epub \
  --live-edge --engine edge --chapter-parallel 2 --segment-seconds 85 \
  --root /tmp/epub2mp3-cli-benchmark \
  --manifest /tmp/epub2mp3-cli-benchmark.json

# Existing throughput-only gate; it evaluates recorded conversion telemetry.
mise run benchmark:check
```

## Exact gaps before performance changes

1. **Apple client:** add a single monotonic-timing seam around gesture/tap,
   first readable text, usable controls, first visual PDF page, seek target
   reached, and audio actually audible. Measure 20 cold and 20 relaunch-warm
   repetitions for EPUB, selectable-text PDF, and sideways two-up scanned PDF;
   report p50/p95 and input size/page count.
2. **Progressive playback:** measure conversion request → first segment
   downloaded → `AVQueuePlayer` ready → audible output. Keep these separate;
   queue creation is not audibility.
3. **Backend dual path:** run three fresh, isolated repetitions per corpus and
   profile through both `converter.py` (CLI) and `server.py` (SSE), recording
   first segment, first complete chapter, full-book wall time, request p50/p95,
   retries, output integrity, peak RSS, and cache hit/miss. Extend the harness
   to PDF before comparing scanned PDFs.
4. **Web:** add browser performance marks for first interactive, reader
   readiness, SSE event to playable audio, and seek completion. Test a cold
   browser profile and an existing-cache profile against the same backend run.
5. **Flutter:** add an integration/profile measurement of the identical flows
   on Android/Linux, including frame timings and first audio; unit tests alone
   cannot establish perceived readiness.
6. **Contention:** on the target Apple device, measure the reader/player while
   a maximum-performance conversion runs. Record frame pacing, CPU, memory,
   thermal state, battery/energy, and dropped playback—not just conversion
   throughput.

There is no native performance test or signpost instrumentation in the current
Apple target: repository search found no `XCTClockMetric`, `XCTestCase.measure`,
`os_signpost`, or `OSSignposter`. The test plan only enables Xcode's
anti-pattern checker ([`EpubToMp3.xctestplan`](../../ios/EpubToMp3/EpubToMp3.xctestplan#L11-L37)).

## Measurement limitation

This Mac must not boot or use an iOS Simulator: the repository's
[local-simulator safety policy](../../AGENTS.md) documents kernel-panic risk on
this Intel 8 GiB host. Apple measurements must run on a physical device or
the macOS/iOS CI runner once the timing seam exists. No Simulator was started
for this research.

## Next unblocked decision

Define the cross-client telemetry contract and Apple timing seam first. It
unblocks a truthful ordering of warm-open, PDF, playback, and conversion
optimizations instead of optimizing whichever subsystem is easiest to change.
