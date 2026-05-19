# CLAUDE.md

Project instructions for **any** Claude assistant working on this repo
(Claude Code, Claude.ai web, Claude Desktop). These rules override all
defaults.

**For Claude.ai web / Desktop:** when the user references "the project",
"the repo", "o projeto", "o app", "o convertido", or any recent topic from
`~/Developer/Epub-to-Mp3/`, assume this project. **Do not ask which
project** — this file is the authoritative context.

## Response Style

Inherits `~/CLAUDE.md` (Zero tokens wasted, pt-BR, action-only). No re-listing here.

## Issue Detection & Auto-Fix

When the user reports a bug ("nao funcionou", "nao limpou", "nao converteu", etc.),
treat it as a **bug report requiring immediate diagnosis and patch** — do not merely
answer questions about it. Reproduce / inspect, fix the root cause, add a regression
test, commit and push without asking for further confirmation (user has standing
authorization for this flow when they explicitly request "corrija e faça commit e push").

## CLI Input Resolution

`python_app/convert` accepts loose multi-word book names and resolves them via:
1. `_normalize_cli_args` — joins space-split tokens into one argument until an
   existing path is found or an option starts.
2. `_collect_files_from_path` — expands files/directories.
3. `_fuzzy_find_book` — **fallback** when the joined tokens don't resolve. Searches
   `~/Downloads` and CWD for EPUB/PDF whose filename fuzzy-matches the query tokens
   (accent-stripped, difflib ratio ≥ 0.75 per token, ≥ 60% of tokens matched).
   Handles typos like `loudo` → `louco` and ignores noise words like the leading
   `downloads` directory name.

**Do not regress this fallback.** Without it, a command like
`convert downloads o loudo de deus --clear-cache` silently falls through to the
global `_clear_cache_all` path (clearing ALL cache instead of the intended book)
and never runs the conversion.

## Project Overview

Full-stack EPUB/PDF to MP3 audiobook converter. Python backend (FastAPI) + React/TypeScript frontend. Three deployment modes that **share the same cache and output directories**:

| Mode | Entry point | Paths |
|------|-------------|-------|
| CLI local | `python -m python_app.main convert` | `PROJECT_ROOT/.cache/`, `PROJECT_ROOT/output/` |
| Web local | `mise run web` / `uvicorn python_app.server:app` | same as CLI |
| HF Spaces | `hf_app.py` (Docker, port 7860) | `/data/epub-to-mp3/.cache/`, `/data/epub-to-mp3/output/` |

CLI and web-local automatically share cache because both use `PROJECT_ROOT` as `PERSISTENT_ROOT`. To override, set `PERSISTENT_ROOT`, `CACHE_DIR`, or `OUTPUT_DIR` env vars.

**TTS Engines** (fastest → slowest): Edge-TTS (cloud) → Piper (offline ONNX, all languages)

---

## #1 Priority: Speed

**Speed is the most critical requirement.** Every design decision must optimize for maximum throughput:

- Maximize CPU and RAM usage by default — never artificially limit resources
- Scale chapter parallelism to available CPU cores automatically
- Use aggressive chunk sizes and concurrency for Edge-TTS
- Scale Piper workers to match available cores
- Prefer parallel chapter conversion over sequential when possible
- Cache parsed text aggressively — never re-parse if cache is valid
- Skip validation overhead for short chapters (< 1500 chars)
- Default to `EXPECTED_WPM=200` (Edge-TTS neural voices) for accurate completion detection

---

## Language Policy

**ALL code, comments, docstrings, log messages, and print statements MUST be in English.**
- No exceptions — not even inline comments
- The i18n system handles user-facing translations in `web/src/i18n/`
- **Intentional Portuguese** (do not translate):
  - Regex patterns matching Portuguese TTS artifacts spoken aloud (`transcription_verifier.py`)
  - Portuguese book-structure keywords used for detection: `capítulo`, `prefácio`, `sumário`, `posfácio`, `dedicatória`, `introdução`, `seção`, `página` (`main.py`, `ebook_reader.py`)
  - PT-BR locale TTS verbal cues in `CUE_LABELS["pt"]`: `em itálico`, `em negrito`, etc. (`text_formatting.py`)
  - Portuguese sample text in language-detection test fixtures (`test_ambiguous_languages.py`, `test_new_features.py`, `test_benchmark_engines.py`)

---

## Test Isolation Rules

- **Never call `importlib.reload(module)` inside tests.** Reload re-executes
  the module body and produces brand-new class objects; other test files
  that imported the module earlier still hold the pre-reload classes, so
  `isinstance`, attribute lookups and monkey-patched instances silently
  diverge. Symptom: tests that pass in isolation but fail in the full
  suite (see commit `47491e7` — `test_chain_tier_allowed.py` reloading
  `converter` broke `test_converter.py::test_convert_chapters_success`
  and `::test_auto_mode_parallel_forwards_pool_per_chapter`).
- To flip a module-level constant captured at import time:
  `unittest.mock.patch.object(module, "CONST", new_value)`.
- If the code under test reads the env var at call time:
  `patch.dict(os.environ, {...})` is enough — no module mutation needed.

## Chapter-Title Announcement

`TextProcessor.apply_structural_speech_cues()` in
`python_app/src/ebook_reader.py` prepends the TOC title to each chapter's
TTS payload so the chapter name is spoken aloud. It suppresses the
prepend only when the title is **substantive** (≥10 chars **and** ≥2
tokens) and is already present as a substring of the first ~4 lines;
short/numeric titles (e.g. Metro 2033 chapters named `"1"`, `"2"`) always
announce unless the first line literally matches. **Do not reintroduce
the old purely-substring suppression** — it silently dropped
announcements for any book whose title collided with an incidental digit
or common word in the opening paragraph.

## Testing Policy

**MANDATORY: every code modification MUST ship with tests.** This is enforced by
`.claude/hooks/test_coverage_gate.sh` (Stop hook). If you edit any file under
`python_app/*.py` (excluding `__init__.py`, `__main__.py`) or
`web/src/**/*.{ts,tsx}` (excluding `.test.*`, `.d.ts`), you MUST also add or
update at least one test file (`python_app/tests/**` or `web/src/**/*.test.{ts,tsx}`)
in the same turn. The Stop hook blocks completion otherwise.

Rules:
- **Every code change ships with tests** — new file → new test; bug fix → regression test; refactor → tests still cover the refactored path
- **All code must be covered** — no source file should exist without at least one test exercising its public surface
- **Always run the full suite before committing**
- **Add tests for every new feature AND every bug fix**
- Critical paths need both unit tests AND integration tests
- Test edge cases: empty chapters, oversized chapters, engine failures

Before committing:
```bash
mise run test           # Full suite: Python + web + lint + build
# OR individually:
pytest -v --tb=short    # Python only (581+ tests)
pytest -v --tb=short python_app/tests/test_edge_engine.py  # Single test file
pytest -v --tb=short -k "test_name"                        # Single test by name
cd web && npm run test  # Web only (17 tests)
```

Escape hatch: if a change is genuinely untestable (comment-only edit, pure
formatting, README update), justify explicitly in the commit message and the
hook's reason field will be acknowledged.

---

## CI Monitoring Policy

**After every `git push`, monitor GitHub CI and fix failures before stopping.**

1. After pushing, the `ci_watch.sh` hook (async PostToolUse) auto-watches the run and injects the result.
2. If CI fails, immediately diagnose via `gh run view <run_id> --log-failed` and push a fix.
3. Do not consider a task done until CI passes green.

```bash
gh run list --limit 3                          # List recent runs
gh run view <run_id>                           # Summary + step status
gh run view <run_id> --log-failed              # Failed step output
gh run watch <run_id>                          # Block until run completes
```

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

### Maintenance
```bash
mise run trim-log       # Trim conversions.jsonl to last 500 entries
mise run hooks-test     # Validate Claude Code hook scripts (syntax + permissions)
mise run audit          # Scan Python dependencies for CVEs (pip-audit)
```

---

## Architecture

### Client surfaces — two apps, one backend

The repo ships two GUI clients on top of the same FastAPI backend.
Each one is its own codebase; the backend is the single source of truth.

| Client | Path | Platforms | Role |
|---|---|---|---|
| **SwiftUI** | `ios/EpubToMp3/` | macOS · iPadOS · iOS | Official Apple client. Library-first reader. macOS embeds the Python server as a sidecar (PyInstaller binary copied into `Contents/Resources/` at build time). iOS / iPadOS talk to a remote backend (`mise run web` or HF Spaces). |
| **Flutter** | `flutter_app/` | Linux · Windows · Android | Official non-Apple client. Single Dart codebase. Talks to the same FastAPI surface. **macOS/iOS are NOT supported** — the SwiftUI app owns those platforms. |

Generic rules:

- **Backend contract is the only shared API** — never reach across
  clients (e.g. don't import Swift types from the Flutter Dart side).
- **`/api/jobs/{id}/stream` (SSE)** drives chapter-by-chapter streaming
  playback in SwiftUI's `PlayerReaderView` — `AudioPlayer.updateSnapshot`
  appends new chapters to the `AVQueuePlayer` queue without
  interrupting playback.
- The **SwiftUI Library hero** persists imported EPUBs in
  `UserDefaults` via `LibraryStore`. Books are identified by SHA-256 of
  file content (survives renames). macOS uses security-scoped
  bookmarks; iOS uses `suitableForBookmarkFile`.

### Dual Conversion Paths — CRITICAL

There are **two completely separate conversion pipelines**:

1. **`converter.py`** — CLI path (`python -m python_app.main convert`)
   - `AudioConverter._convert_chapters_parallel()` — main chapter loop
   - Three-tier fallback: Edge multilingual → Edge monolingual → Piper
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
hf_app.py          HF Spaces wrapper — serves React + API
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
    └── piper_engine.py  Piper ONNX (all languages, subprocess-based)
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
CACHE_OUTPUT_MAX_BYTES=2147483648  # Combined .cache/ + output/ size budget in bytes.
                         # Default 2 GiB. LRU eviction (oldest-first) runs when
                         # total size exceeds this. Active-job directories are
                         # never evicted. Enforced by server's periodic cleanup
                         # worker AND at CLI start + after each conversion.
CACHE_OUTPUT_TTL_HOURS=24  # Entries (book dirs in .cache/ or output/) whose newest
                         # file mtime is older than this many hours are always
                         # evicted, regardless of budget. Default 24 h.
                         # Set to a large value (e.g. 99999) to disable TTL.
```

### Edge-TTS Tuning
```bash
EDGE_CHUNK_CHARS=12000           # Chars per request (HF: 12K, local: 12K).
                                 # Default `_DEFAULT_CHUNK_SIZE` was raised
                                 # from 10K → 12K in v0.3.10; 15K is the safe
                                 # ceiling, the auto-tuner reduces below 12K
                                 # only after a real failure.
EDGE_MAX_CONCURRENCY=12          # Parallel requests (HF: 1, local: 12)
EDGE_MAX_CONCURRENCY_CAP=8       # Hard upper bound; defaults to 8 for shared
                                 # egress hosts. Local installs may opt up to
                                 # 16 (raised from 8 in v0.3.10) without
                                 # touching source.
EDGE_RECOVERY_SUCCESS_THRESHOLD=7 # Consecutive Edge successes required before
                                 # the auto-tuner scales concurrency/chunk
                                 # back up after a rate-limit burst (was 15).
EDGE_NOAUDIO_COOLDOWN_SECONDS=15 # Cooldown when Edge returns empty payload
                                 # AND the health probe also fails (was 60s).
                                 # A false-positive on a 1-minute idle book
                                 # was stalling whole queues.
EDGE_SEGMENT_OK_RATIO=0.95       # Keep MP3 when ≥95% of segments synthesise
                                 # successfully (v0.3.8). Set to 1.0 for
                                 # archival/strict mode.
EDGE_MAX_SEGMENT_SECONDS=85      # Max audio segment duration
EDGE_SAFE_CHAPTER_PARALLEL=8     # Parallel chapters in safe mode
CHAPTER_PARALLEL_COUNT=0         # Auto-detect from CPU cores (0=auto)
EDGE_MIN_CHARS_PER_SECOND=45     # Slow mode trigger (HF auto-sets to 100)
EDGE_SLOW_RATIO_THRESHOLD=2.5    # Slow mode trigger ratio (HF auto-sets to 1.5)
```

### Local Engines
```bash
PIPER_CHUNK_CHARS=5000           # Chars per Piper chunk (was 3000; fewer subprocess calls)
PIPER_MAX_PROCS=0                # Auto-detect from CPU (0=auto)
DISABLE_PIPER_FALLBACK=0         # Set to 1 to skip Piper and retry Edge instead
ENGINE_CHAIN_FALLBACK=0          # Default off: stay on Edge (multi → mono) and
                                 # never cascade to Piper for whole
                                 # chapters. Per-chunk fallback still handles
                                 # isolated hangs (CLI --fallback-engine or
                                 # FALLBACK_ENGINE_OVERRIDE). Set to 1 to
                                 # restore the legacy multi-tier cascade.
FALLBACK_ENGINE_OVERRIDE=auto    # Operator-level fallback constraint, read by
                                 # both the CLI (secondary to --fallback-engine)
                                 # and server's _build_engine_chain. Values:
                                 # auto|none|piper.
                                 # "none" strips all offline fallbacks; a specific
                                 # engine filters the chain to that tier only.
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

### Misc Operator Switches
```bash
EDGE_AUTO_OFFLINE_SECONDS        # Window after a 403/timeout in which Edge is
                                 # treated as offline; `_engine_selection_mixin`
                                 # short-circuits to the next tier without
                                 # retrying. Read by `ConversionConfig`.
EPUB2MP3_VENV_BOOTSTRAPPED       # Internal flag set by the CLI when it
                                 # auto-bootstraps `.venv` after detecting an
                                 # `externally-managed-environment` pip error.
                                 # Prevents re-execing into the venv twice.
                                 # Do NOT set manually.
MENU_FORCE_TTY                   # Force the interactive menu to use raw termios
                                 # mode even when stdin/stdout are not a TTY
                                 # (useful for SSH/CI). Values: 1|true|yes|on.
CLI_CHAPTER_HARD_TIMEOUT_SECONDS=900  # Hard per-chapter ceiling for the CLI
                                      # parallel runner; scales by +15s per 1K
                                      # chars over 20K. Set to 0 to disable.
```

---

## TTS Engine Fallback System

### CLI Path (`converter.py`)
Three-tier progressive fallback per chapter, with adaptive delays:

1. **Edge multilingual** — best quality, prone to rate limiting on HF shared IPs
   - Chapter backoff: 0.5s → 1s → 2s → 4s → 8s → 16s → 30s (cap)
   - Request backoff: 5s → 10s → 20s → 40s → 60s (cap), resets after 15 successes + 60s
2. **Edge monolingual** — after `EDGE_MONOLINGUAL_THRESHOLD=3` failures
3. **Piper** — after `EDGE_PIPER_THRESHOLD=3` more failures (all languages)

### Server Path (`server.py`)
Per-job engine chain + slow detection:
- `_build_engine_chain()` → `edge → piper` (ranked by telemetry speed)
- Slow mode: if `chars/s < EDGE_MIN_CHARS_PER_SECOND` OR `elapsed > estimated × ratio`
  → `_apply_edge_slow_mode()` (reduces chunks, disables parallel)
- **Edge disabled for whole job** if: slow mode active + next healthcheck still slow,
  OR 2+ consecutive chapter timeouts (`edge_chapter_timeouts` counter)
- `_CHAPTER_RETRY_FOREVER = False` — prevents infinite loops when all engines fail

### Language Support
- **Piper**: all languages (model downloaded on first use, cached in `/models/piper/`)

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
RUN apt-get install -y ffmpeg libsndfile1
```

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
| 35 CVEs in pip-audit (aiohttp, pypdf, flask, nltk, requests, filelock, etc.) | Bumped direct deps + added transitive security pins in requirements.txt; `pip upgrade` in Dockerfile |
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

---

## Tooling Policy

**Always use `mise` for all toolchain management and task execution — never install or invoke tools natively.**

- **All tools** (Python, Node, npm packages) are managed via `mise.toml` — never `brew install`, `nvm`, `pip install -g`, or `npm install -g` directly
- **All project tasks** run via `mise run <task>` — never call `python`, `node`, `pyinstaller`, etc. directly in the terminal
- Adding a new tool: add it to `[tools]` in `mise.toml`, then `mise install`
- Adding a new task: add it to `mise.toml` under `[tasks."name"]`, not as a standalone script

### Native macOS build (SwiftUI)
- Local: `mise run mac:build` — runs `sidecar:build` then `xcodebuild` headlessly, producing `ios/EpubToMp3/.build/Build/Products/Release/EpubToMp3.app`
- Sidecar only: `mise run sidecar:build` — produces `dist/epub-to-mp3-server` (PyInstaller onefile)
- Requires `xcodegen` (brew install xcodegen). Xcode is optional — `mac:build` is fully headless

### Mobile builds
- Web bundle only (no IDE): `mise run mobile:build` — produces `web/dist/` configured for HF Spaces backend
- Native iOS/Android packages: built automatically by `release-desktop.yml` CI on tag push

### Flutter companion (`flutter_app/`)
- Toolchain: Flutter 3.41.9 pinned in `mise.toml`. Use `mise exec -- flutter ...` (or the `flutter:*` tasks) — never a system-wide `flutter`.
- Tasks: `mise run flutter:run`, `flutter:test`, `flutter:analyze`, `flutter:build-apk`.
- Models use freezed + json_serializable. Regenerate with `mise exec -- dart run build_runner build --delete-conflicting-outputs` after editing any class under `flutter_app/lib/models/`.
- Wire format mirrors iOS slice 3: `JobSnapshot` / `EbookFulltext` are camelCase; `SessionRecord` is snake_case (legacy session log).
