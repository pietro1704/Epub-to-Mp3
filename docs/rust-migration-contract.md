# Rust Migration Contract

**Status:** frozen inventory of the current Python/FastAPI, CLI, native Apple, and Flutter contracts.

**Source snapshot:** repository state inspected for Phase 0, Task 0.1 on 2026-09-27. This document records observed behavior; it does not introduce a replacement API. Where clients and backend disagree, both sides are recorded explicitly so the Rust implementation can preserve compatibility deliberately.

## 1. Deployment targets and process boundaries

| Target | Current entry point | Transport / port | Persistent root and role |
|---|---|---|---|
| Local CLI | `python -m python_app.main convert ...` (also `./convert`) | process-local | Project root by default: `.cache/`, `output/`, `.jobs/`, `.uploads/`, `.job_inputs/`, `.source_backups/`, `.logs/`, `models/` |
| Local web | `mise run web` / `uvicorn python_app.server:app` | FastAPI; commonly `8000` | Same project tree and cache as CLI unless path overrides are set |
| macOS desktop | UIKit/AppKit app in `ios/EpubToMp3/`; PyInstaller sidecar from `desktop.spec` | sidecar default `EPUB_TO_MP3_PORT=47860` | `PERSISTENT_ROOT` is set to writable Application Support by `PythonEmbed.swift`; sidecar PID file is optional |
| iOS/iPadOS | `ios/EpubToMp3/` | remote FastAPI backend; native app uses `URLSession` | Application Support for native local data; conversion backend is remote. The embedded-Python path remains present in the inspected tree and is not assumed removable by this contract |
| Flutter Android | `flutter_app/`; release workflow builds APK with Chaquopy | remote FastAPI API plus embedded Python conversion support in current release workflow | App documents/downloads cache; downloads are `<documents>/downloads/<jobId>/` |
| Flutter Linux | `flutter_app/`; release workflow | remote FastAPI API | App documents/downloads cache |
| Flutter Windows | `flutter_app/`; release workflow | remote FastAPI API | App documents/downloads cache |
| Hugging Face Space | `hf_app.py` in `Dockerfile` | container port `7860` (overridable with `PORT`) | `/data/epub-to-mp3` when `SPACE_ID` is set; `.cache`, `output`, `.jobs`, uploads and related state survive Space restarts |
| Docker local | `Dockerfile`; `mise run docker:run` | published `7860:7860` | Container persistent root behavior follows `SPACE_ID`/environment configuration |

The Flutter client documentation says macOS/iOS are owned by the native Apple app; the release workflow therefore produces Android, Linux, and Windows Flutter artifacts, while the Apple job produces the macOS package and an unsigned iOS archive attempt.

## 2. HTTP routes

Routes are mounted under `/api` unless stated otherwise. FastAPI JSON uses the field names shown below; `JobStatus` and job snapshots are camelCase on the wire.

### Health and system

| Method and path | Current response / behavior |
|---|---|
| `GET /api/health` | `{status: "healthy", version, storage: {local_output_dir}, limits: {max_upload_bytes, max_upload_mb}}`; may include `monitor` with heap, memory, CPU, GPU, and thread data |
| `GET /api/health/monitor` | Health monitor statistics object |
| `GET /api/health/alerts?max_count=50` | `{alerts: [{timestamp, severity, category, message, details}], count}` |
| `GET /api/health/dashboard` | `{summary, current, recent_alerts}`; `current` contains CPU/memory/GPU/heap/thread fields |
| `GET /api/health/recovery` | `{stats, recent_actions: [{timestamp, problem, action, success, details}]}` |
| `GET /api/system/stats` | Hardware/scheduler recommendation payload from `_build_system_stats_payload()` |
| `POST /api/system/restart` | Optional JSON `{keep_cache: boolean, keep_finished: boolean}`. Returns `{status: "restarting", purgedJobs, keptCache, keptFinished}` and schedules process exit |

### Uploads

| Method and path | Request | Response / behavior |
|---|---|---|
| `POST /api/uploads` | Multipart `file`; default maximum is 100 MiB (`MAX_UPLOAD_MB`) | `{uploadId, fileName, bookTitle, bookAuthor, coverUrl, coverMimeType}`. Stores pending upload and metadata; cover may be extracted and chapter parsing is pre-cached in a background task |
| `POST /api/uploads/local` | JSON `{path: absolute local path}`; loopback callers only (`127.0.0.1`, `::1`, localhost variants) | Same upload metadata response. Copies into managed upload storage; supported suffixes include `.epub`, `.pdf`, `.fb2`, `.docx`, `.cbz`, `.cbr`, `.mobi`, `.prc`, `.azw`, `.azw3` |
| `GET /api/uploads/{upload_id}/fulltext` | URL upload id | Parsed pending-upload document, using `parse_epub_to_dict`; `404` expired/missing, `422` parse failure |
| `GET /api/uploads/{upload_id}/{filename}` | URL upload id and safe leaf filename | Uploaded asset via `FileResponse`; `400` traversal, `404` missing |

### Conversion submission

`POST /api/convert` accepts multipart form data. Either `file` or a previously returned `upload_id` is required. The current exact accepted form fields are:

| Field | Current meaning |
|---|---|
| `file` | Direct uploaded EPUB/PDF/etc. |
| `upload_id` | Reuse pending `/api/uploads` or `/api/uploads/local` data |
| `engine` | Default `edge`; CLI choices are `auto`, `edge`, `piper` |
| `voice`, `model`, `language` | Engine/model/language selection |
| `chapters`, `sections` | Chapter/section selectors |
| `fromChapterToEnd`, `fromChapterToChapter` | Range selectors; both together are rejected (`400`); range syntax is `A..B` |
| `footnote_mode` | `inline` default; current configuration supports `inline`, `chapter_end`, `skip` |
| `priority`, `priority_chapter_index` | Priority selectors / chapter index |
| `formatting_cues`, `enable_character_voices`, `narrator_voice`, `character_voice` | Speech formatting and multi-voice options; booleans accept form flag values |
| `export_to_iphone` | macOS/iCloud export opt-in |
| `no_parallel`, `multi_engine_parallel`, `max_performance`, `parallel_slots` | Scheduling/performance controls |
| `chapter_stall_seconds` | Chapter watchdog override, clamped to 10–900 seconds |
| `edge_network_tier` | `slow`, `medium`, `fast`, or `ultra` |
| `edge_chunk_chars`, `edge_max_segment_seconds`, `edge_enable_parallel`, `edge_auto_tune`, `edge_stable_mode` | Edge controls |
| `piper_max_procs` | Piper process limit |
| `engine_chain_fallback` | Enable Edge → Piper cascade |
| `bitrate`, `sample_rate`, `channels` | Audio output controls; sample rate is clamped to 8,000–96,000 and channels to 1–2 |
| `clear_cache`, `force_reprocess`, `filter_chapters`, `verbose` | Cache, selection, and logging controls |
| `use_language_detection`, `prioritize_primary_language` | Language policy controls |
| `health_check_interval_seconds`, `health_check_slow_edge_cps`, `health_check_slow_cps`, `health_check_high_cpu`, `health_check_high_mem`, `health_check_ok_cpu`, `health_check_ok_mem`, `health_check_slow_streak` | Per-job health/watchdog overrides |
| `ui_language` | UI locale; server normalizes to `pt` or `en` |

Successful submission returns exactly `{ "jobId": "<uuid>" }`. The job is initially `queued`, persisted before response, and then enqueued for background conversion.

### Jobs and persisted state

| Method and path | Response / behavior |
|---|---|
| `GET /api/jobs/{job_id}` | `JobStatus` snapshot; `404` if not found. May rehydrate metadata from existing outputs |
| `GET /api/jobs/{job_id}/stream` | SSE stream of the same job snapshots; initial `data:` frame is sent immediately; heartbeat comments are `: heartbeat`; closes on terminal state |
| `POST /api/jobs/{job_id}/cancel` | `{status}`; queued jobs become `cancelled`, running jobs first become `cancelling` |
| `POST /api/jobs/{job_id}/resume` | Requeues an interrupted/failed job; returns status object (exact implementation response is the current source of truth) |
| `DELETE /api/jobs/{job_id}` | Removes job and/or output state; returns status object (clients expect `{status}`) |
| `GET /api/jobs/{job_id}/log` | Plain-text persisted conversion log; `404` if absent |
| `POST /api/jobs/{job_id}/journey-observations` | JSON `{journeyId: UUID, transition, elapsedNanoseconds}`; allowed transitions are `play_requested`, `audio_queued`, `audio_audible`, `seek_requested`, `seek_target_reached`, `cancelled`; success `{status: "recorded"}` |
| `GET /api/jobs/{job_id}/fulltext` | `{jobId, bookTitle, bookAuthor, chapters[]}`. `200` from cache/parse, `503` while source is transiently unavailable, `404` missing terminal source, `422` parseable book with no chapters |
| `GET /api/jobs/resumable` | `{resumable_jobs: [{jobId, state, bookTitle, fileName, savedAt, chaptersCompleted, chaptersTotal, engine, voice, language, formattingCues, uiLanguage}], count}` |
| `GET /api/jobs/recent?limit=10` | `{jobs: [...], count}` |
| `GET /api/outputs/{job_id}/{filename}` (`GET`, `HEAD`) | Safe file download from the job output directory; used for MP3, ZIP, cover and log assets |
| `GET /api/streams/{job_id}/chapters/{chapter_index}` | `{jobId, chapterIndex, baseUrl, chunks: [{id, index, file, url, durationSeconds?, text?, observation?}], updatedAt}` |
| `GET /api/streams/{job_id}/chapters/{chapter_index}/chunks/{chunk_id}` | Audio chunk bytes, with range/stream behavior as implemented by the current server; safe chunk id and path validation are required |

### Sessions, voices, estimates, telemetry, and sample

| Method and path | Response / behavior |
|---|---|
| `GET /api/sessions?last=0` | `{sessions: [...], count, stats: {outcomes, engines, modes, total_duration_seconds, total_chapters_converted}}`; `last` is clamped to 0–1000 |
| `DELETE /api/sessions` | `{deleted: number}`; clears the persistent session log |
| `GET /api/voices` | `{voices: [...]}` curated by the TTS provider |
| `GET /api/voice-preview?engine=<edge\|piper>&voice=<voice>&language=<lang>` | MP3 `audio/mpeg`; cached under `.cache/voice-previews`; rate limit is 10 requests/IP/minute; invalid engine `400`, limit `429` |
| `GET /api/estimate?upload_id=<id>&engine=auto` | Estimate payload with `chapters`, `total_chars`, primary engine, chars/sec, telemetry flag/sample count, duration, output MB, `engine_estimates`, and `chapter_breakdown` |
| `GET /api/telemetry` | `{engines: {...}, recent: [{engine, chars, synth_seconds, timestamp}]}` |
| `GET /api/telemetry/segments` | `{available, summary, source}` |
| `GET /api/telemetry/feature-history?limit=20` | `{available, history, entries, count, source}`; limit is clamped to 1–200 |
| `GET /sample.epub` | Serves the bundled sample EPUB when available |
| `POST /api/cleanup?max_age_hours=48` | Deletes old output directories, job JSON, and telemetry; returns counts including `local_deleted`, `jobs_deleted`, `telemetry_deleted`, `errors` |

## 3. Job snapshot JSON

`GET /api/jobs/{id}` and ordinary SSE `data:` frames use this camelCase shape. Optional fields may be omitted/null:

```json
{
  "jobId": "uuid",
  "state": "queued|running|finished|failed|interrupted|cancelling|cancelled",
  "events": ["human-readable event strings"],
  "rawLog": ["raw log strings"],
  "detectedLanguage": "pt",
  "chaptersTotal": 12,
  "chaptersCompleted": 3,
  "currentChapter": "Chapter title",
  "progressPercent": 25.0,
  "chapterProgress": [
    {
      "index": 0,
      "name": "Chapter 1",
      "status": "pending|processing|completed|skipped|failed|cancelled|retrying",
      "engine": "edge",
      "engineSequence": ["edge"],
      "elapsedSeconds": 1.2,
      "charsPerSecond": 110.0,
      "chars": 1200,
      "charsProcessed": 1200,
      "progressRatio": 1.0,
      "wordCount": 220,
      "downloadUrl": "/api/outputs/<job>/<file>.mp3",
      "retryCount": 0,
      "maxRetries": 6,
      "retryReason": null,
      "paramAdjustment": null,
      "errorCategory": null,
      "errorMessage": null
    }
  ],
  "totalSegments": 10,
  "completedSegments": 3,
  "outputs": [{"name": "001 - Chapter 1.mp3", "url": "/api/outputs/...", "sizeBytes": 12345}],
  "error": null,
  "bookTitle": "Book",
  "bookAuthor": "Author",
  "coverUrl": "/api/outputs/<job>/cover.jpg",
  "coverMimeType": "image/jpeg",
  "logUrl": "/api/jobs/<job>/log",
  "parallelSlots": 8,
  "parallelActive": 2,
  "statusHint": "...",
  "engine": "edge",
  "voice": "en-US-AriaNeural",
  "language": "pt",
  "formattingCues": true,
  "uiLanguage": "pt",
  "lastActivityAt": 1710000000.0,
  "noParallel": false,
  "journeyObservations": []
}
```

Clients treat `finished`, `failed`, `interrupted`, and `cancelled` as terminal. Existing Swift/Dart models intentionally ignore unknown fields, so additive fields are currently tolerated but renaming/removing fields is not safe.

## 4. SSE contract

Endpoint: `GET /api/jobs/{job_id}/stream`, content type `text/event-stream`.

Observed event forms:

1. **Initial/default snapshot**

   ```text
   data: {"jobId":"...","state":"queued",...}

   ```

2. **Typed chapter update**: server broadcasts a frame with an event name of `chapter_update` and a JSON payload containing chapter update data. The client TypeScript EventSource path listens for the typed event and merges it into the job snapshot; Flutter's raw parser consumes `data:` JSON lines and ignores the `event:` label.

   ```text
   event: chapter_update
   data: {"jobId":"...", ...chapter fields...}

   ```

3. **Heartbeat comment**

   ```text
   : heartbeat

   ```

   Heartbeats are not JSON events and are intentionally invisible to browser `EventSource` consumers. The web client has a 25-second idle reconnect watchdog.

4. **Terminal snapshot**: an ordinary `data:` snapshot with `state` in `finished`, `failed`, `interrupted`, or `cancelled`; the server then closes the stream.

The Swift native client also has a raw `JobEvent` representation and independently decodes the `data:` payload. The stream is long-lived; clients must not apply an ordinary finite resource timeout.

## 5. Download and output paths

### Backend filesystem

`python_app/src/paths.py` is the source of truth:

- `PROJECT_ROOT`: discovered by walking from `python_app/src` to `.git`, `pytest.ini`, `requirements-hf.txt`, or `CLAUDE.md`.
- `PERSISTENT_ROOT`: `PROJECT_ROOT` normally; `/data/epub-to-mp3` when `SPACE_ID` is set; writable per-user Application Support for a frozen desktop bundle; explicit `PERSISTENT_ROOT` always wins.
- `CACHE_DIR`: explicit `CACHE_DIR`, otherwise `PROJECT_ROOT/.cache` locally, or `PERSISTENT_ROOT/.cache` for Space/frozen/explicit-root operation.
- `OUTPUT_DIR`: explicit `OUTPUT_DIR`, otherwise `PROJECT_ROOT/output` locally, or `PERSISTENT_ROOT/output` for Space/frozen/explicit-root operation.
- `JOBS_DIR`: `PERSISTENT_ROOT/.jobs`, job state `<jobId>.json`.
- `UPLOADS_DIR`: `PERSISTENT_ROOT/.uploads`, pending upload subdirectory `<uploadId>/` and `upload.json` metadata.
- `JOB_INPUTS_DIR`: `PERSISTENT_ROOT/.job_inputs`, per-job source directory `<jobId>/`.
- `SOURCE_BACKUPS_DIR`: `PERSISTENT_ROOT/.source_backups`.
- `MODELS_DIR`: `PROJECT_ROOT/models` normally; `PERSISTENT_ROOT/models` when an explicit persistent-root override is used.
- `PIPER_MODELS_DIR`: `<MODELS_DIR>/piper`; exported as `PIPER_MODEL_DIR` unless already set.
- `TELEMETRY_DIR`: `<CACHE_DIR>/telemetry`.
- `LOGS_DIR`: `PERSISTENT_ROOT/.logs`; persistent session log is `.logs/conversions.jsonl`.
- Voice previews: `<CACHE_DIR>/voice-previews/*.mp3`.
- Cover cache: `<OUTPUT_DIR>/.cover_cache/index.json`.
- Book cache: `<CACHE_DIR>/<book-slug>/` plus parsed TOC/cache records managed by `CacheManager`.
- Book output: `<OUTPUT_DIR>/<book-slug>/` in new jobs. Legacy jobs may use `<OUTPUT_DIR>/<jobId>/`. A job's persisted `outputDir` is authoritative once selected.
- Stream files: `<job output>/streams/<jobId>/index.json` and chunk files; legacy streams may be directly under the book's `streams/` directory when the manifest explicitly belongs to the job.
- Chapter MP3 and ZIP/other assets are served through `/api/outputs/{job_id}/{filename}`.

Job JSON is written atomically through a PID-suffixed temporary file and `os.replace`; `_saved_at` is added on disk and removed when loaded. The in-memory cache is authoritative during a process, while disk state enables restart/resume/rehydration. Resumable states are `queued` and `running` when scanning persisted files.

### Client offline download paths

- Flutter: `<application documents>/downloads/<jobId>/<filename>`; offline cache eviction scans the same `downloads/` tree.
- Native Apple: downloaded/streamed files are stored in app-managed local library/application-support locations; server URLs are resolved against the configured backend. The native source uses `PERSISTENT_ROOT` for embedded conversion storage, not for remote HTTP downloads.

## 6. CLI commands and flags

Entry point defaults to conversion. Subcommands:

- `convert [INPUT] [EXTRA_INPUTS...] [flags]`
- `menu [flags]`
- `clear-cache [BOOK]`

The positional input accepts EPUB/PDF files, directories, glob/batch sources, and the repository's fuzzy book-name fallback. Current public conversion flags (including aliases) are:

```text
--engine {auto,edge,piper}
--fallback-engine {auto,piper,none}
--engine-chain-fallback
--prewarm-edge
--prewarm-piper
--inject-title-pause MS
--voice VOICE
--model MODEL
--output-dir DIR
--show-structure
--detect-language / --show-language
--filter-chapters
--verbose / --no-verbose
--formatting-cues / --no-formatting-cues
--character-voices / --no-character-voices
--narrator-voice VOICE
--character-voice VOICE
--listen
--export-to-iphone
--no-parallel
--multi-engine
--no-footnote
--footnote-chapter-end
--clear-cache
--no-cache
--resume-from-failure / --no-resume-from-failure
--verify / --verify-only
--fix
--verify-transcription / --audio-verify
--no-verify-transcription / --no-audio-verify
--deep-validate / --no-deep-validate
--validate-during-conversion
--auto-validate-output / --no-auto-validate-output
--auto-fix-output / --no-auto-fix-output
--no-validate
--validate-text / --no-validate-text
--validate-audio / --no-validate-audio
--strict-validate
--transcription-model {tiny,base,small,medium,large}
--validation-language LANG
--chapter CHAPTER (repeatable)
--from-chapter-to-end CHAPTER
--from-chapter-to-chapter A..B
--section SECTION (repeatable)
--priority PRIORITY (repeatable)
--language LANG
--use-language-detection / --no-language-detection
--prioritize-primary-language / --no-prioritize-primary-language
--ui-language {pt,en}
--max-performance
--overnight
--profile {speed}
--speed-scenario {auto,balanced,edge-fast,offline-heavy}
--parallel-slots N
--chapter-stall-seconds SECONDS
--edge-chunk-chars N
--edge-max-segment-seconds N
--edge-network-tier {slow,medium,fast,ultra}
--edge-enable-parallel / --edge-disable-parallel
--edge-auto-tune / --no-edge-auto-tune
--edge-stable-mode / --no-edge-stable-mode
--piper-max-procs / --piper-workers N
--piper-chunk-chars N
--bitrate RATE
--sample-rate HZ
--channels {1,2}
--force-reprocess
--health-check-interval-seconds N
--health-check-slow-edge-cps N
--health-check-slow-cps N
--health-check-high-cpu N
--health-check-high-mem N
--health-check-ok-cpu N
--health-check-ok-mem N
--health-check-slow-streak N
--retry-failed N
--retry-failed-manual
--show-metrics-summary
--show-metrics-dashboard
--open-metrics-dashboard
--export-metrics-bundle
--prefetch / --no-prefetch
--stage-pipeline / --no-stage-pipeline
--stage-pipeline-depth N
--ab-auto / --no-ab-auto
--adaptive-checkpoint / --no-adaptive-checkpoint
--batch PATH (repeatable)
--batch-file FILE
--stop-on-error
--menu
```

`--clear-cache` without a book performs global cleanup; with a book it is book-scoped. `--no-cache` is the non-destructive “ignore existing cache/output for this book” path.

## 7. Environment variables

The following variables are observable in the current runtime and are part of the compatibility inventory. Defaults shown are current defaults where they are defined at import/configuration time; variables without a value are feature switches or deployment-provided values.

### Paths, deployment, and process

- `PERSISTENT_ROOT`, `CACHE_DIR`, `OUTPUT_DIR`, `PIPER_MODEL_DIR`, `XDG_DATA_HOME`, `APPDATA`
- `SPACE_ID` (HF Space selector), `PORT` (default `7860` in `hf_app.py` and server main), `SERVER_MODE`
- `EPUB_TO_MP3_PORT` (desktop sidecar default `47860`), `EPUB_TO_MP3_SIDECAR_PID_FILE`
- `FRONTEND_URL`, `CLOUDFLARE_PAGES_URL`
- `MAX_UPLOAD_MB` (default `100`), `UPLOAD_TTL_SECONDS` (local default 30 days; HF default 1 hour)
- `COMPLETED_JOB_TTL_HOURS` (local default 4; HF default 48), `CLEANUP_INTERVAL_SECONDS` (local default 300; HF default 60), `TELEMETRY_RETENTION_HOURS` (default 720)
- `JOB_WORKERS` (default 1), `JOB_WORKERS_MAX` (default 16), `MAX_CONCURRENT_BOOKS` (default 1), `MAX_CHAPTERS_PER_JOB` (default unlimited), `MAX_CHAPTER_CHARS` (default 0/unlimited)
- `DISABLE_AUTO_RECOVERY`, `AUTO_RECOVERY_IGNORE_PREFIXES`, `ENABLE_AUTO_TUNING` (default enabled), `ENABLE_ADAPTIVE_PERFORMANCE`
- `CUDA_VISIBLE_DEVICES` (server defaults empty), `FORCE_CUDA` (server defaults `0`), `FORCE_CPU_ONLY` (server defaults `1`), `DISABLE_TORCH`, `ALLOW_TORCH_NO_SHM`, `DISABLE_NUMPY_OPTIMIZATIONS`

### Engine and audio behavior

- `EXPECTED_WPM` (default `200`), `FALLBACK_ENGINE_OVERRIDE`, `ENGINE_CHAIN_FALLBACK`, `DISABLE_PIPER_FALLBACK`, `DISABLE_PIPER`, `ENABLE_PIPER`, `FORCE_PIPER_NATIVE_DEPS`, `EPUB_TO_MP3_ENGINE`
- `EDGE_CHUNK_CHARS` (config default 12,000), `EDGE_MAX_SEGMENT_SECONDS` (config default 85), `EDGE_ENABLE_PARALLEL` (default true), `EDGE_MAX_CONCURRENCY` (config default 12), `EDGE_NETWORK_TIER`, `EDGE_AUTO_TUNE`, `EDGE_ADAPTIVE_SEGMENT_SECONDS`, `EDGE_ADAPTIVE_SEGMENT_MAX_SECONDS`
- `EDGE_SAFE_CHUNK_CHARS`, `EDGE_SAFE_MAX_SEGMENT_SECONDS`, `EDGE_SAFE_CHAPTER_PARALLEL`, `EDGE_SAFE_TIMEOUT_MAX`, `EDGE_AUTO_PARALLEL_CAP_SLOW`, `EDGE_AUTO_PARALLEL_CAP_MEDIUM`, `EDGE_AUTO_PARALLEL_CAP_FAST`, `EDGE_AUTO_PARALLEL_CAP_ULTRA`, `EDGE_MIN_CHARS_PER_SECOND`, `EDGE_SLOW_RATIO_THRESHOLD`
- `EDGE_MAX_CONCURRENCY_CAP`, `EDGE_MAX_CONCURRENCY_SOURCE`, `EDGE_NETWORK_HOST`, `EDGE_NETWORK_PROBE`, `EDGE_NETWORK_PROBE_ATTEMPTS`, `EDGE_NETWORK_PROBE_PAUSE`, `EDGE_NETWORK_PROBE_TIMEOUT`, `EDGE_NETWORK_ABORT_AFTER_FAILS`, `EDGE_NOAUDIO_COOLDOWN_SECONDS`, `EDGE_RECOVERY_SUCCESS_THRESHOLD`, `EDGE_SEGMENT_MAX_RETRIES`, `EDGE_STREAM_MAX_RETRIES`, `EDGE_BATCH_DELAY_MS`, `EDGE_IDENTITY_ROTATION_WINDOW`, `EDGE_IDENTITY_VOICES`, `EDGE_FIRST_CHUNK_CHARS`, `EDGE_MIN_VALID_CHUNK_BYTES`, `EDGE_PIPER_THRESHOLD`, `EDGE_AUTO_OFFLINE_SECONDS`, `EDGE_AUTO_OFFLINE_CHARS`, `EDGE_QUICK_SYNTH_TIMEOUT`, `EDGE_SEGMENT_OK_RATIO`, `EDGE_TRUNCATION_RATIO`
- `PIPER_MAX_PROCS` (default 2 in relevant engine paths), `PIPER_CHUNK_CHARS` (default 3000), `PIPER_PREFETCH_LANG`, `PIPER_QUICK_SYNTH_TIMEOUT`, `PIPER_CHUNK_MAX_RETRIES`, `PIPER_CHUNK_STALL_SECONDS`, `PIPER_LARGE_TIMEOUT_MIN`, `PIPER_LARGE_TIMEOUT_MAX`, `PIPER_LARGE_TIMEOUT_MAX_50K`, `PIPER_LARGE_TIMEOUT_MAX_100K`, `PIPER_LARGE_TIMEOUT_MAX_200K`
- `BITRATE` is not read as a global; bitrate is a CLI/form field. `SAMPLE_RATE` and `CHANNELS` likewise travel in request/config objects.

### Scheduling, validation, and telemetry

- `CHAPTER_PARALLEL_COUNT`, `CHAPTER_PARALLEL_MAX`, `CHAPTER_PARALLEL_COUNT_SOURCE`, `CHAPTER_STALL_SECONDS`, `CHAPTER_RETRY_MAX`, `CHAPTER_RETRY_ROUNDS`, `CHAPTER_RETRY_FOREVER_MAX`, `CHAPTER_RETRY_BACKOFF_SECONDS`, `CHAPTER_SEGMENT_IDLE_SECONDS`
- `JOB_STALL_THRESHOLD_SECONDS` (default 300), `JOB_STALL_RECHECK_SECONDS` (default 90), `JOB_STALL_MAX_AUTO_RETRIES` (default 1)
- `JOB_HEALTHCHECK_INTERVAL_SECONDS` (default 15), `JOB_HEALTHCHECK_SLOW_EDGE_CPS`, `JOB_HEALTHCHECK_SLOW_CPS`, `JOB_HEALTHCHECK_HIGH_CPU_PERCENT` (default 85), `JOB_HEALTHCHECK_HIGH_MEM_PERCENT` (default 85), `JOB_HEALTHCHECK_OK_CPU_PERCENT` (default 75), `JOB_HEALTHCHECK_OK_MEM_PERCENT` (default 80), `JOB_HEALTHCHECK_SLOW_STREAK` (default 1)
- `CHECKPOINT_INTERVAL` (default 5), `MAX_VALIDATION_RETRIES`, `AUTO_VALIDATE_OUTPUT`, `QUICK_SYNTH_MAX_CHAPTERS`, `QUICK_SYNTH_MAX_CHARS`, `SUPPRESS_VALIDATION_ERRORS`, `TRUNCATION_THRESHOLD_PERCENT`, `FORCE_STATIC_PROGRESS`
- `PERF_PROFILE`, `BENCHMARK_PROFILE_MODE`, `BENCHMARK_PROFILE_PATH`, `THERMAL_POWER_MODE`, `CACHE_OUTPUT_TTL_HOURS`, `CACHE_OUTPUT_MAX_BYTES`, `AUTO_SKIP_MIN_CHARS`, `AUTO_SKIP_EXTRA`
- `AUTO_TUNE_CACHE_FILE`, `AUTO_TUNE_CACHE_TTL_SECONDS`, `AUTO_TUNE_USE_CACHE`, `MULTI_ENGINE_EDGE_FRACTION`, `LOCAL_ENGINE_STALL_MIN_SECONDS`, `GENERIC_QUICK_SYNTH_TIMEOUT`, `QUICK_SYNTH_MAX_CHARS`, `ETA_HINT_MAX_AGE_SECONDS`
- `EXPORT_TO_IPHONE`, `IPHONE_EXPORT_DIR`, `IOS_EDGE_CHUNK_CHARS`, `IOS_EDGE_RETRY_BACKOFF_SECONDS`, `IOS_VALIDATE_AUDIO`, `PRESERVE_TTS_LAYOUT`

### Non-production/test context variables observed in source

`PYTEST_CURRENT_TEST`, `PYTEST_VERSION`, `LANG`, `MENU_FORCE_TTY`, `SKIP_NETWORK_TESTS`, and `FORCE_BENCHMARK_TESTS` affect test/development behavior and should not be accidentally promoted to production configuration.

No secret values are included in this contract. CI secrets such as `GITHUB_TOKEN`, `HF_TOKEN`, `HF_SSH_PRIVATE_KEY`, and provider keys remain deployment secrets and are intentionally not copied here.

## 8. Release artifacts and automation

### CI and deployment workflows

- `.github/workflows/ci.yml`: mise-managed Python tests/lint/smoke, web tests/lint/build, Flutter tests/analyzer.
- `.github/workflows/sync-hf.yml`: after successful master CI, creates an HF-only snapshot excluding iOS/Flutter and pushes it to `pi1704/epub-to-mp3`; then polls `/api/health`.
- `.github/workflows/rollback-hf.yml`: manually synchronizes a selected/previous commit to HF and checks health.
- `.github/workflows/release-desktop.yml`: tag/manual release workflow.
- `.github/workflows/auto-release.yml`: manually creates version tags and dispatches `release-desktop.yml`.
- Other workflows cover CodeQL, security audits, benchmark history, dependabot, and CI diagnosis; they do not define user-facing conversion artifacts.

### Release outputs currently built or published

| Artifact | Current producer | Notes |
|---|---|---|
| Docker image `ghcr.io/<owner>/epub-to-mp3` | `release-desktop.yml` Docker job | semver tags and `latest`; port 7860 image |
| `EpubToMp3_android.apk` | Flutter Android job | release APK uploaded to GitHub release |
| `EpubToMp3-macos-<tag>.zip` | Apple job | zipped `EpubToMp3.app`; uploaded to GitHub release |
| unsigned iOS archive `build-ios/EpubToMp3.xcarchive` | Apple job | archive attempt is allowed to warn and continue; no `.ipa` upload is currently defined |
| `EpubToMp3-flutter-linux-<tag>.tar.gz` | Flutter desktop Linux job | uploaded to GitHub release |
| `EpubToMp3-flutter-windows-<tag>.zip` | Flutter desktop Windows job | uploaded to GitHub release |
| `dist/epub-to-mp3-server` | local/CI PyInstaller sidecar from `desktop.spec` | copied into macOS app resources during build; current release builds it inline |
| web `web/dist/` | web build and mobile bundle tasks | production frontend bundle; HF snapshot includes web assets as configured |

The release workflow currently bootstraps Python into Android and Apple packaging paths, and builds the macOS sidecar with PyInstaller. These are current deployment artifacts and dependencies that the Rust migration must explicitly replace or remove rather than silently dropping.

## 9. Compatibility constraints for the Rust rewrite

1. Preserve all routes above, including upload staging, local desktop upload, fulltext retry statuses, chapter stream manifests/chunks, session history, telemetry, health, and restart operations.
2. Preserve camelCase job JSON and the existing snake_case session-log records returned inside `/api/sessions`.
3. Preserve SSE `data:` snapshots, typed `chapter_update`, heartbeat comments, terminal closure, and long-lived connection semantics.
4. Preserve path override precedence and the stable on-disk job/cache/output layouts, including legacy output/job recovery.
5. Preserve CLI selectors, fuzzy input resolution, engine flags, validation controls, and global-vs-book-scoped cache semantics.
6. Preserve release artifact names/targets unless a later migration task explicitly records a deliberate compatibility break.
7. Do not copy or expose secrets while implementing parity.
