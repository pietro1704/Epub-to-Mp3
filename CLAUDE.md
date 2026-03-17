# CLAUDE.md

Project instructions for Claude Code. These rules override all defaults.

## Project Overview

Full-stack EPUB/PDF to MP3 audiobook converter. Python backend (FastAPI) + React/TypeScript frontend. Three deployment modes that **share the same cache and output directories**:

| Mode | Entry point | Paths |
|------|-------------|-------|
| CLI local | `python -m python_app.main convert` | `PROJECT_ROOT/.cache/`, `PROJECT_ROOT/output/` |
| Web local | `mise run web` / `uvicorn python_app.server:app` | same as CLI |
| HF Spaces | `hf_app.py` (Docker, port 7860) | `/data/epub-to-mp3/.cache/`, `/data/epub-to-mp3/output/` |

CLI and web-local automatically share cache because both use `PROJECT_ROOT` as `PERSISTENT_ROOT`. To override, set `PERSISTENT_ROOT`, `CACHE_DIR`, or `OUTPUT_DIR` env vars.

**TTS Engines** (fastest → slowest): Edge-TTS (cloud) → Kokoro (local neural, EN/JA/ZH) → Piper (offline ONNX, all languages)

---

## #1 Priority: Speed

**Speed is the most critical requirement.** Every design decision must optimize for maximum throughput:

- Maximize CPU and RAM usage by default — never artificially limit resources
- Scale chapter parallelism to available CPU cores automatically
- Use aggressive chunk sizes and concurrency for Edge-TTS
- Scale Kokoro/Piper workers to match available cores
- Prefer parallel chapter conversion over sequential when possible
- Cache parsed text aggressively — never re-parse if cache is valid
- Skip validation overhead for short chapters (< 1500 chars)
- Default to `EXPECTED_WPM=200` (Edge-TTS neural voices) for accurate completion detection

---

## Language Policy

**ALL code, comments, docstrings, log messages, and print statements MUST be in English.**
- No exceptions — not even inline comments
- The i18n system handles user-facing translations in `web/src/i18n/`
- Only intentional Portuguese: regex patterns in `transcription_verifier.py` that match Portuguese TTS artifacts spoken aloud

---

## Testing Policy

**Always test after every change.** Before committing:
```bash
mise run test           # Full suite: Python + web + lint + build
# OR individually:
pytest -v --tb=short    # Python only (581+ tests)
cd web && npm run test  # Web only (17 tests)
```
- Add tests for every new feature or bug fix
- Critical paths need both unit tests AND integration tests
- Test edge cases: empty chapters, oversized chapters, engine failures
- The 2 skipped tests are Coqui GPU tests — acceptable

---

## Commands

### Setup
```bash
mise run install        # Recommended — auto-configures Python 3.11 venv + npm
# OR manually:
pip install -r requirements.txt && brew install ffmpeg espeak-ng
```

### CLI Conversion
```bash
source .venv/bin/activate   # REQUIRED for Piper fallback

python -m python_app.main convert book.epub                    # Basic
python -m python_app.main convert book.epub --engine edge      # Force Edge-TTS
python -m python_app.main convert book.epub --chapter 3        # Single chapter
python -m python_app.main convert book.epub --show-structure   # Preview + save cache
python -m python_app.main convert book.epub --clear-cache      # Force reprocess
python -m python_app.main convert book1.epub book2.pdf --batch ~/folder/
```

### Web Server
```bash
mise run web                                    # Recommended (sets up everything)
uvicorn python_app.server:app --port 8000       # Direct
python hf_app.py                                # HF Spaces entry (port 7860)
```

### Frontend
```bash
cd web && npm run dev    # Dev server (Vite, hot reload)
cd web && npm run build  # Production build
```

---

## Architecture

### Dual Conversion Paths — CRITICAL

There are **two completely separate conversion pipelines**:

1. **`converter.py`** — CLI path (`python -m python_app.main convert`)
   - `AudioConverter._convert_chapters_parallel()` — main chapter loop
   - Four-tier fallback: Edge multilingual → Edge monolingual → Kokoro → Piper
   - Adaptive delays, retry backoff, deferred safe pass
   - `AudioConverter` uses 8 mixins:
     `_HealthWatchdogMixin`, `_MetricsReportMixin`, `_OutputFileMixin`, `_CacheMixin`,
     `_EdgeThrottleMixin`, `_EngineSelectionMixin`, `_RetryMixin`, `_ValidationMixin`

2. **`server.py`** — Web/API path (`process_conversion()` → `convert_chapter()`)
   - Completely separate engine chain, timeout logic, retry logic
   - `_build_engine_chain()` → `_switch_to_next_engine()` → `_maybe_retry()`
   - Has its own slow-mode detection, healthcheck, stall watchdog
   - Heavy logic extracted into 4 helper submodules in `src/`:
     - `_server_engine_helpers.py` — engine chain, perf profile, language normalisation
     - `_server_job_helpers.py` — job persistence, cleanup, progress checkpoints
     - `_server_audio_helpers.py` — audio hashing, duplicate detection, output sorting
     - `_server_conversion_helpers.py` — per-chapter progress helpers extracted from `process_conversion`

**Any feature added to one path MUST be mirrored in the other.**

### Backend (`python_app/`)
```
main.py            CLI entry — argument parsing, book loading, orchestration
server.py          FastAPI server — job queue, async conversion, SSE streaming
hf_app.py          HF Spaces wrapper — serves React + API, Kokoro pre-warm
src/
├── config.py                    ConversionConfig dataclass
├── converter.py                 CLI conversion orchestration (DUAL PATH)
│   ├── _health_watchdog_mixin.py
│   ├── _metrics_report_mixin.py
│   ├── _output_file_mixin.py
│   ├── _cache_mixin.py
│   ├── _edge_throttle_mixin.py
│   ├── _engine_selection_mixin.py
│   ├── _retry_mixin.py
│   └── _validation_mixin.py
├── _server_engine_helpers.py    Engine chain, perf profile, language helpers
├── _server_job_helpers.py       Job persistence, cleanup, checkpoints
├── _server_audio_helpers.py     Audio hashing, duplicate detection, output sort
├── _server_conversion_helpers.py Per-chapter progress helpers
├── ebook_reader.py    EPUB/PDF parsing, TOC hierarchy (NCX + EPUB3 nav)
├── cache_manager.py   Per-chapter text cache in .cache/Book_Title/
├── job_manager.py     Async job queue with persistent .jobs/*.json
├── engine_pool.py     TTS engine resource pooling
├── progress.py        CLI progress bar — active chapters, engine, ETA
├── telemetry.py       Engine performance tracking (chars/s per engine)
├── session_logger.py  Persistent conversion log (conversions.jsonl)
├── error_classifier.py TTS error → stable category mapping
└── tts/
    ├── edge_engine.py  Edge-TTS (cloud, 12K chunks, rate-limit backoff)
    ├── kokoro_engine.py Kokoro (82M params, EN/JA/ZH, needs espeak-ng)
    ├── piper_engine.py  Piper ONNX (all languages, subprocess-based)
    └── coqui_engine.py  Coqui XTTS (GPU recommended)
```

### Frontend (`web/src/`)
```
App.tsx                     Main app, lazy panels
hooks/useConversionFlow.ts  Conversion state machine
services/ConversionService.ts API client (SSE + polling)
components/ChapterProgressList.tsx  Per-chapter status + audio player
i18n/translations.ts        pt-BR and en-US translations
```

### Shared Paths (`paths.py`)
```
PERSISTENT_ROOT = PROJECT_ROOT (local) | /data/epub-to-mp3 (HF)
CACHE_DIR       = PERSISTENT_ROOT/.cache/     # Parsed text per book
OUTPUT_DIR      = PERSISTENT_ROOT/output/     # Final MP3s + ZIPs
JOBS_DIR        = PERSISTENT_ROOT/.jobs/      # Web job metadata (JSON)
UPLOADS_DIR     = PERSISTENT_ROOT/.uploads/   # Uploaded EPUBs (web only)
MODELS_DIR      = PROJECT_ROOT/models/        # TTS model files (always local)
```

---

## Key Environment Variables

### Conversion Limits
```bash
MAX_CHAPTER_CHARS=0      # Skip chapters larger than N chars (0=disabled).
                         # Auto-warns when any chapter is >5× median size.
                         # Use for EPUBs with footnote-container chapters (e.g.
                         # Companhia das Letras: Sumário chapter = entire book).
EXPECTED_WPM=200         # TTS speed for audio validation (Edge neural = ~200 WPM)
COMPLETED_JOB_TTL_HOURS  # Default: 48h on HF, 4h local. Files persist this long.
```

### Edge-TTS Tuning
```bash
EDGE_CHUNK_CHARS=12000           # Chars per request (HF: 12K, local: 12K)
EDGE_MAX_CONCURRENCY=12          # Parallel requests (HF: 1, local: 12)
EDGE_MAX_SEGMENT_SECONDS=85      # Max audio segment duration
EDGE_SAFE_CHAPTER_PARALLEL=8     # Parallel chapters in safe mode
CHAPTER_PARALLEL_COUNT=0         # Auto-detect from CPU cores (0=auto)
EDGE_MIN_CHARS_PER_SECOND=45     # Slow mode trigger (HF auto-sets to 100)
EDGE_SLOW_RATIO_THRESHOLD=2.5    # Slow mode trigger ratio (HF auto-sets to 1.5)
```

### Local Engines
```bash
KOKORO_CHUNK_CHARS=2000          # Chars per Kokoro chunk
KOKORO_MAX_WORKERS=0             # Auto-detect from CPU (0=auto)
PIPER_MAX_PROCS=0                # Auto-detect from CPU (0=auto)
SPARK_CHUNK_CHARS=1500           # Chars per Spark chunk
SPARK_MAX_WORKERS=1              # GPU-bound
```

### Server Timeouts (auto-tuned by profile)
```bash
_CHAPTER_TIMEOUT_MIN=60          # Min timeout per chapter (was 120s)
_CHAPTER_TIMEOUT_MAX=120(HF)/300 # Max timeout — HF gets 120s for faster fallback
_CHAPTER_RETRY_FOREVER=False     # MUST be False — True causes infinite loops
_CHAPTER_RETRY_ROUNDS=3          # Retry rounds before giving up on a chapter
JOB_STALL_THRESHOLD_SECONDS=300  # Stall detection (was 480s)
JOB_HEALTHCHECK_INTERVAL_SECONDS=15 # Slow detection (HF: 10s)
JOB_HEALTHCHECK_SLOW_STREAK=1    # HF: 1 consecutive slow check triggers slow mode
```

---

## TTS Engine Fallback System

### CLI Path (`converter.py`)
Four-tier progressive fallback per chapter, with adaptive delays:

1. **Edge multilingual** — best quality, prone to rate limiting on HF shared IPs
   - Chapter backoff: 0.5s → 1s → 2s → 4s → 8s → 16s → 30s (cap)
   - Request backoff: 5s → 10s → 20s → 40s → 60s (cap), resets after 15 successes + 60s
2. **Edge monolingual** — after `EDGE_MONOLINGUAL_THRESHOLD=3` failures
3. **Kokoro** — after `EDGE_KOKORO_THRESHOLD=3` more failures (EN/JA/ZH only)
4. **Piper** — after `EDGE_PIPER_THRESHOLD=3` more failures (all languages)

### Server Path (`server.py`)
Per-job engine chain + slow detection:
- `_build_engine_chain()` → `edge → kokoro → piper` (ranked by telemetry speed)
- Slow mode: if `chars/s < EDGE_MIN_CHARS_PER_SECOND` OR `elapsed > estimated × ratio`
  → `_apply_edge_slow_mode()` (reduces chunks, disables parallel)
- **Edge disabled for whole job** if: slow mode active + next healthcheck still slow,
  OR 2+ consecutive chapter timeouts (`edge_chapter_timeouts` counter)
- `_CHAPTER_RETRY_FOREVER = False` — prevents infinite loops when all engines fail

### Language Support
- **Kokoro**: EN, JA, ZH only. For pt-BR → skipped, falls to Piper
- **Piper**: all languages (model downloaded on first use, cached in `/models/piper/`)
- **espeak-ng system package** required for Kokoro — must be in Dockerfile

---

## HF Spaces Specifics

The Space uses a Docker image (`Dockerfile`). When code changes, GitHub CI syncs to HF, which rebuilds the Docker image.

### Auto-applied HF profile (when `SPACE_ID` is set)
```
EDGE_MAX_CONCURRENCY=1    CHAPTER_PARALLEL_MAX=1    EDGE_CHUNK_CHARS=12000
EDGE_ENABLE_PARALLEL=false   (serial chunks, minimize request count)
EDGE_MIN_CHARS_PER_SECOND=100  EDGE_SLOW_RATIO_THRESHOLD=1.5
_CHAPTER_TIMEOUT_MAX=120s      JOB_HEALTHCHECK_INTERVAL_SECONDS=10
EDGE_SAFE_CHUNK_CHARS=5000     EDGE_SAFE_TIMEOUT_MAX=180
COMPLETED_JOB_TTL_HOURS=48     (outputs survive overnight on /data)
```

### Keep-alive
- Background task pings `http://localhost:{PORT}/api/health` every 10 min
- Uses localhost only — pinging the public URL causes HF 429 rate limits
- HF's sleep detection is based on external browser traffic, not internal pings

### Dockerfile requirements
```dockerfile
RUN apt-get install -y ffmpeg libsndfile1 espeak-ng
```
- `espeak-ng` is required for Kokoro to work (phoneme generation)
- Without it, Kokoro silently fails and only Piper is available

### Persistent Storage
- Files on `/data/epub-to-mp3/` survive restarts
- Jobs (.jobs/), outputs (output/), cache (.cache/) all on `/data`
- TTL: 48h for completed job outputs, 30 days for telemetry

---

## Quality of Life for Audiobooks

These features exist specifically to improve the audiobook listening experience:

- **TOC hierarchy preserved**: Chapter numbers like `4.1`, `4.2` reflect EPUB TOC structure
- **Chapter numbering**: NCX (EPUB2) and nav.xhtml (EPUB3) both supported, hierarchy-aware
- **Oversized chapter detection**: Auto-warns when a chapter is >5× median size with `MAX_CHAPTER_CHARS` suggestion
- **Streaming playback**: Segments available in web UI as they're synthesized
- **Per-chapter download**: Individual MP3s + full ZIP + chapter manifest
- **Retry with deferred safe pass**: Hard chapters deferred to end for offline retry
- **Audio validation**: Detects truncation using WPM-based duration check (skip if < 1500 chars)
- **Progress ETA**: Uses per-chapter telemetry + chunk progress for accurate estimates
- **Skipped chapters**: Shown as ⏭️ in UI (not counted as failures)

---

## EPUB Parsing

- `ebook_reader.py` tries NCX first (EPUB2), then nav.xhtml (EPUB3)
- TOC hierarchy levels propagate to chapters: level 1 = part, level 2 = chapter, etc.
- Min-level wins when multiple TOC entries map to same file (anchor sharing)
- `--show-structure` saves parsed text to `.cache/` for subsequent conversion reuse
- Duplicate chapter detection: Jaccard 3-gram similarity, removes exact/near-duplicate content

---

## Critical Bugs Fixed (do not reintroduce)

| Bug | Fix |
|-----|-----|
| `_CHAPTER_RETRY_FOREVER = True` → infinite loop when all engines fail | Set to `False`, use `_CHAPTER_RETRY_ROUNDS=3` |
| `EXPECTED_WPM=160` → 80% coverage on complete Edge audio → false truncation | Changed to `200` |
| Missing `espeak-ng` in Dockerfile → Kokoro fails silently on HF | Added to apt-get |
| Keep-alive pinging public URL → HF 429 for users | Use localhost only |
| Edge slow (66 chars/s) never triggered fallback on HF | HF threshold 100 chars/s, 1.5x ratio |
| Chapter timeout 300s on HF → 5 min per stuck chapter | 120s on HF |
| `validate_audio_completeness` skip threshold 1000 chars too low | Raised to 1500 chars |
| `_sort_output_entries` called before definition (false alarm) | Python function scope — OK |
| Stall watchdog heartbeat not updating `_lastActivityTs` | Added `_update_job_activity()` to heartbeat |

---

## Design Patterns

- **Factory**: `TTSFactory` creates engine instances by name
- **Job Queue**: `JobManager` handles async conversion with persistent JSON state
- **Caching**: `CacheManager` stores parsed text per chapter in `.cache/Book_Title/`
- **Adaptive Resilience**: Exponential backoff + automatic engine fallback
- **Auto-Scaling**: Workers and parallelism auto-scale to available hardware
- **Progress tracking**: `ProgressTracker` (CLI) with `_active_chapters`, `_active_engine`, ETA hints
- **Dual path**: Features in `converter.py` must be mirrored in `server.py`

---

## Development Guidelines

- **All code in English** — no exceptions
- **Test every change** — `mise run test` before commit
- **Mirror features** — `converter.py` ↔ `server.py` (see Dual Path)
- Follow factory pattern for new TTS engines
- Preserve chapter structure from EPUB TOC (NCX/nav)
- `source .venv/bin/activate` required before CLI conversions (Piper needs it)
- Default to aggressive performance settings (max CPU/RAM)
- Progress bar denominator: only chapters to be converted (exclude cached)
- Commit messages in English, concise, focus on "why"
