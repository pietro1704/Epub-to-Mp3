# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Full-stack EPUB/PDF to MP3 audiobook converter. Python backend with FastAPI server and React/TypeScript frontend. Deployed as Docker container on Hugging Face Spaces.

**TTS Engines**: Edge-TTS (Microsoft cloud), Coqui TTS (local neural), Kokoro (fast local), Spark-TTS (LLM-based), Piper (local ONNX)

## Language Policy

**ALL code, comments, docstrings, log messages, print statements, and UI text MUST be in English.**
- No Portuguese (or any non-English language) in source code
- The i18n system handles user-facing translations separately
- Variable names, function names, and identifiers must be in English
- Commit messages in English

## Performance Policy

**Always maximize CPU and RAM usage by default.** The app should automatically:
- Scale chapter parallelism to available CPU cores (not conservative defaults)
- Use aggressive chunk sizes and concurrency for Edge-TTS
- Scale Piper/Kokoro workers to match available cores
- Never artificially limit resources unless rate-limited by external services

## Commands

### Python Setup
```bash
# Requires Python 3.11 (Coqui TTS compatibility)
# Use mise for automatic env setup (recommended):
mise run install

# Or manually:
pip install -r requirements.txt
# FFmpeg required: brew install ffmpeg (macOS) or apt install ffmpeg (Linux)
```

### CLI Usage
**IMPORTANT**: Always activate venv before running conversions to ensure Piper fallback works:
```bash
source .venv/bin/activate

# Then run commands:
python -m python_app.main convert book.epub                    # Basic conversion
python -m python_app.main convert book.epub --menu             # Interactive engine/voice selection
python -m python_app.main convert book.epub --engine edge      # Force Edge-TTS
python -m python_app.main convert book.epub --chapter 3        # Single chapter
python -m python_app.main convert book.epub --show-structure   # Preview chapters
python -m python_app.main convert book.epub --clear-cache      # Reprocess from scratch
# Batch conversion
python -m python_app.main convert book1.epub book2.pdf --batch ~/folder/
```

### Benchmarking
```bash
source .venv/bin/activate
python benchmark_engines.py book.epub --engines edge,piper --chapters 3
```

### API Server
```bash
python hf_app.py                                       # HF Spaces entry (port 7860)
uvicorn python_app.server:app --port 8000              # Direct server
```

### Web Frontend
```bash
cd web
npm install
npm run dev          # Development server (Vite)
npm run build        # Production build (tsc + vite)
npm run lint         # ESLint
npm run test         # Vitest
```

### Testing
```bash
# Python tests
pytest -v --tb=short
pytest python_app/tests/test_ebook_reader.py -v       # Single file
pytest -k "test_chapter_extraction"                    # Single test by name

# Web tests
cd web && npm run test
```

## Architecture

### Backend (`python_app/`)
```
main.py                # CLI entry point
server.py              # FastAPI server with job queue
src/
├── config.py          # ConversionConfig dataclass
├── converter.py       # Core conversion orchestration
├── ebook_reader.py    # EPUB/PDF parsing
├── cache_manager.py   # Chapter-level caching in .cache/Book_Title/
├── job_manager.py     # Async job queue for API
├── engine_pool.py     # TTS engine resource pooling
├── telemetry.py       # Engine performance tracking
└── tts/
    ├── factory.py      # TTSFactory (factory pattern)
    ├── base.py         # TTSEngine abstract base
    ├── edge_engine.py  # Edge-TTS (cloud, 12K char chunks, 12 concurrent, 85s segments)
    ├── coqui_engine.py # Coqui XTTS (neural local, GPU recommended)
    ├── kokoro_engine.py# Kokoro (fast local, 82M params, EN/JA/ZH)
    ├── spark_engine.py # Spark-TTS (LLM-based, voice cloning)
    └── piper_engine.py # Piper ONNX (basic local)
```

### Frontend (`web/`)
React 18 + TypeScript + Vite. Key files:
- `src/App.tsx` - Main app with lazy-loaded panels
- `src/hooks/useConversionFlow.ts` - Conversion state machine
- `src/services/ConversionService.ts` - API client with SSE/polling

### Deployment
- `Dockerfile` - Multi-stage: Node build → Python runtime
- `hf_app.py` - Hugging Face Spaces entry point (serves React + API)
- `.github/workflows/sync-hf.yml` - Auto-deploy to HF on push

## Key API Endpoints
- `POST /api/convert` - Upload EPUB, start job
- `GET /api/jobs/{id}` - Job status with chapter progress
- `GET /api/jobs/{id}/stream` - SSE real-time updates
- `GET /api/outputs/{id}/{file}` - Download MP3
- `GET /api/voices` - Available voices by engine
- `GET /api/telemetry` - Engine performance stats

## Environment Variables

### Edge-TTS Tuning
```bash
EDGE_CHUNK_CHARS=12000          # Chars per request (default 12K, max 15K)
EDGE_MAX_CONCURRENCY=12         # Parallel requests (aggressive default)
EDGE_MAX_SEGMENT_SECONDS=85     # Max audio segment duration
EDGE_SAFE_CHAPTER_PARALLEL=8    # Parallel chapters
CHAPTER_PARALLEL_COUNT=0        # Auto-detect from CPU cores (0=auto)
# Four-tier fallback system:
EDGE_MONOLINGUAL_THRESHOLD=3    # Switch to monolingual Edge after N failures
EDGE_KOKORO_THRESHOLD=3         # Switch to Kokoro after N failures (after monolingual)
EDGE_PIPER_THRESHOLD=3          # Switch to Piper after N failures (after Kokoro)
```

### Conversion Limits
```bash
MAX_CHAPTER_CHARS=0             # Skip chapters larger than N chars (0=disabled)
                                # Useful for EPUBs where TOC/footnote files embed the
                                # entire book text (e.g. Companhia das Letras EPUBs).
                                # The app auto-detects and warns about outliers (>5× median).
EXPECTED_WPM=200                # Expected TTS speaking speed for audio validation
                                # (Edge-TTS neural voices: ~200 WPM)
```

### Kokoro Tuning
```bash
KOKORO_CHUNK_CHARS=2000         # Chars per chunk
KOKORO_MAX_WORKERS=0            # Auto-detect from CPU cores (0=auto, default=cpu/2)
```

### Piper Tuning
```bash
PIPER_MAX_PROCS=0               # Auto-detect from CPU cores (0=auto, default=cpu_count)
```

### Spark-TTS Tuning
```bash
SPARK_TTS_MODEL_DIR=pretrained_models/Spark-TTS-0.5B  # Model directory
SPARK_CHUNK_CHARS=1500          # Chars per chunk
SPARK_MAX_WORKERS=1             # Workers (GPU-bound)
```

## Four-Tier Fallback System & Adaptive Delays

**Edge-TTS Resilience System** (updated Feb 2026):

When using Edge-TTS, the system automatically handles rate limiting and service degradation with a **four-tier progressive fallback**:

### Tier 1: Edge-TTS Multilingual (Default)
- Uses multilingual neural voices (e.g., `pt-BR-ThalitaMultilingualNeural`)
- Best quality but more prone to rate limiting under heavy load
- **Two independent backoff systems** run simultaneously:
  - **Chapter-level adaptive delay** (`converter.py`, `base_delay=0.5s`, cap `30s`):
    Scales with consecutive chapter failures: 0.5s → 1s → 2s → 4s → 8s → 16s → 30s
  - **Request-level rate limit backoff** (`edge_engine.py`, starts 5s, cap `60s`):
    Triggered by 403 responses from Edge-TTS: 5s → 10s → 20s → 40s → 60s (capped)
    Resets automatically after 15 consecutive successes and 60s+ without limits

### Tier 2: Edge-TTS Monolingual (after 3 failures)
- Automatically switches to monolingual (language-specific) voice
- Uses non-multilingual voices which may have less rate limiting
- Maintains cloud quality with potentially better stability

### Tier 3: Kokoro Local (after 3 more failures)
- Falls back to Kokoro (local neural TTS, 82M params)
- Supports EN/JA/ZH only
- No rate limits, uses CPU

### Tier 4: Piper Offline (after 3 more failures)
- Falls back to Piper (offline ONNX)
- Uses detected book language for appropriate model selection
- Continues conversion with offline engine (no rate limits)

### Language Detection
- System analyzes **at least 5 chapters** and **5000+ characters** for confident language detection
- Uses weighted voting across multiple samples
- Ensures accurate language selection for monolingual and Piper fallbacks

### Failure Tracking
- Counts consecutive failures (truncation, validation errors, timeouts)
- Resets counter on successful chapter conversion
- Logs detailed failure metrics for debugging

## Design Patterns
- **Factory**: TTSFactory creates engine instances by name
- **Job Queue**: JobManager handles async conversion with progress callbacks
- **Caching**: CacheManager stores parsed text per chapter for resume
- **Adaptive Resilience**: Exponential backoff + automatic fallback for service degradation
- **Auto-Scaling**: Workers and parallelism auto-scale to available hardware

## Guidelines
- **All code and comments in English** - no exceptions
- Follow existing factory pattern for new TTS engines
- Preserve chapter structure from EPUB navigation (NCX/nav)
- Validate engine dependencies before use (ffmpeg, model files)
- **Always activate venv** before running conversions (required for Piper fallback)
- Keep changes minimal and focused
- Default to aggressive performance settings (max CPU/RAM usage)
- Progress bar denominator should show only chapters to be converted (exclude cached)
