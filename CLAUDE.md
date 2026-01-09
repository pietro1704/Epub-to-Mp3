# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Full-stack EPUB/PDF to MP3 audiobook converter. Python backend with FastAPI server and React/TypeScript frontend. Deployed as Docker container on Hugging Face Spaces.

**TTS Engines**: Edge-TTS (Microsoft cloud), Coqui TTS (local neural), Kokoro (fast local), Spark-TTS (LLM-based), Piper (local ONNX)

## Commands

### Python Setup
```bash
# Requires Python 3.11 (Coqui TTS compatibility)
pip install -r requirements.txt
# FFmpeg required: brew install ffmpeg (macOS) or apt install ffmpeg (Linux)
```

### CLI Usage
```bash
python -m python_app.main book.epub                    # Basic conversion
python -m python_app.main book.epub --menu             # Interactive engine/voice selection
python -m python_app.main book.epub --engine edge      # Force Edge-TTS
python -m python_app.main book.epub --chapter 3        # Single chapter
python -m python_app.main book.epub --show-structure   # Preview chapters
python -m python_app.main book.epub --clear-cache      # Reprocess from scratch
# Batch conversion
python -m python_app.main convert book1.epub book2.pdf --batch ~/folder/
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
    ├── edge_engine.py  # Edge-TTS (cloud, 10K char chunks, 8 concurrent, 85s segments)
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
EDGE_CHUNK_CHARS=10000          # Chars per request (default 10K, max 15K)
EDGE_MAX_CONCURRENCY=8          # Parallel requests (optimal)
EDGE_MAX_SEGMENT_SECONDS=85     # Max audio segment duration
EDGE_SAFE_CHAPTER_PARALLEL=8    # Parallel chapters
```

### Kokoro Tuning
```bash
KOKORO_CHUNK_CHARS=2000         # Chars per chunk
KOKORO_MAX_WORKERS=2            # Parallel workers
```

### Spark-TTS Tuning
```bash
SPARK_TTS_MODEL_DIR=pretrained_models/Spark-TTS-0.5B  # Model directory
SPARK_CHUNK_CHARS=1500          # Chars per chunk
SPARK_MAX_WORKERS=1             # Workers (GPU-bound)
```

## Design Patterns
- **Factory**: TTSFactory creates engine instances by name
- **Job Queue**: JobManager handles async conversion with progress callbacks
- **Caching**: CacheManager stores parsed text per chapter for resume

## Guidelines
- Follow existing factory pattern for new TTS engines
- Preserve chapter structure from EPUB navigation (NCX/nav)
- Validate engine dependencies before use (ffmpeg, model files)
- Keep changes minimal and focused
