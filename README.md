---
title: EPUB to MP3 Converter
emoji: 📚
colorFrom: blue
colorTo: purple
sdk: docker
pinned: false
license: mit
---

# EPUB to MP3 Converter

Convert EPUB/PDF ebooks into MP3 audiobooks using neural TTS engines.

**Live Demo**: [Hugging Face Space](https://huggingface.co/spaces/pi1704/epub-to-mp3)

---

## Download

Pre-built desktop app (updated on every commit):

| Platform | Download |
|---|---|
| **macOS** (Apple Silicon) | `.dmg` from [Releases](https://github.com/pietro1704/Epub-to-Mp3/releases) · `brew install --cask epub-to-mp3` |
| **Windows** (x64) | `*_x64-setup.exe` or `*.msi` from [Releases](https://github.com/pietro1704/Epub-to-Mp3/releases) |
| **Linux** (Flatpak) | `*.flatpak` from [Releases](https://github.com/pietro1704/Epub-to-Mp3/releases) · `flatpak install Epub.to.Mp3_x86_64.flatpak` |
| **Linux** (Snap) | `*.snap` from [Releases](https://github.com/pietro1704/Epub-to-Mp3/releases) · `snap install --dangerous Epub.to.Mp3_x86_64.snap` |
| **Linux** (AppImage / deb) | `*.AppImage` or `*.deb` from [Releases](https://github.com/pietro1704/Epub-to-Mp3/releases) |
| **Linux** (AUR) | `yay -S epub-to-mp3-bin` |
| **Android** | `EpubToMp3_android.apk` from [Releases](https://github.com/pietro1704/Epub-to-Mp3/releases) |
| **iOS** (sideload) | `EpubToMp3_ios.ipa` — install via AltStore or Sideloadly |
| **Docker** | `docker pull ghcr.io/pietro1704/epub-to-mp3:latest` |

---

## Features

- **Three TTS engines**: Edge-TTS (cloud, fastest) → Kokoro (local neural, EN/JA/ZH) → Piper (offline ONNX, all languages)
- **Automatic fallback**: engines fail over automatically; the fastest available engine wins
- **Smart cache**: parsed text cached per-book — re-runs skip re-parsing
- **Chapter structure**: preserves TOC hierarchy (NCX / EPUB3 nav), numbered `1.0 / 1.1 / 1.2`
- **Batch conversion**: queue multiple EPUB/PDF files or entire folders
- **Web UI**: React frontend with real-time per-chapter progress, streaming playback, and ZIP download
- **Audio validation**: WPM-based truncation detection, auto-retry with engine fallback
- **Progress ETA**: per-chapter telemetry + chunk tracking for accurate estimates

---

## Quick Start

### Recommended (mise)

```bash
git clone https://github.com/pietro1704/Epub-to-Mp3.git
cd Epub-to-Mp3
mise run install        # Sets up Python 3.11 venv + npm + Piper binary
```

### Manual

```bash
pip install -r requirements.txt
brew install ffmpeg espeak-ng   # macOS; use apt on Linux
```

---

## CLI Usage

```bash
source .venv/bin/activate   # Required for Piper fallback

# Basic conversion
python -m python_app.main convert book.epub

# Force a specific engine
python -m python_app.main convert book.epub --engine edge
python -m python_app.main convert book.epub --engine piper

# Single chapter or range
python -m python_app.main convert book.epub --chapter 3
python -m python_app.main convert book.epub --chapter 5.1,5.2,5.3

# Preview chapter structure (saves parsed text to cache)
python -m python_app.main convert book.epub --show-structure

# Force re-parse (ignore cache)
python -m python_app.main convert book.epub --clear-cache

# Batch: multiple files or folder
python -m python_app.main convert book1.epub book2.pdf --batch ~/folder/

# Interactive menu (pick engine/voice/settings)
python -m python_app.main convert book.epub --menu
```

### Shell Autocomplete (Optional)

```bash
# Zsh (macOS default) — add to ~/.zshrc
echo "source $(pwd)/shell-completion.zsh" >> ~/.zshrc && source ~/.zshrc
```

Tab-completes `.epub`/`.pdf` file paths and `--engine` values.

---

## Web Server

```bash
mise run web                            # Recommended
uvicorn python_app.server:app --port 8000   # Direct
python hf_app.py                        # HF Spaces entry (port 7860)
```

Frontend dev server (hot reload):

```bash
cd web && npm run dev
```

---

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/convert` | Upload EPUB/PDF and start conversion |
| `GET` | `/api/jobs/{job_id}` | Conversion status + SSE progress stream |
| `POST` | `/api/jobs/{job_id}/cancel` | Cancel a queued/running job |
| `GET` | `/api/outputs/{job_id}/{filename}` | Download MP3 / ZIP |
| `GET` | `/api/voices` | Curated voice list for the frontend |
| `GET` | `/api/telemetry` | Aggregated engine throughput (chars/s) |
| `GET` | `/api/health` | Health check |
| `GET` | `/api/sessions` | Conversion session log |
| `DELETE` | `/api/sessions` | Clear session log |

Uploads are capped at **100 MB** by default. Override:

```bash
export MAX_UPLOAD_MB=200          # backend
export VITE_MAX_UPLOAD_MB=200     # frontend build
```

---

## Key Environment Variables

### Edge-TTS Tuning

```bash
EDGE_CHUNK_CHARS=12000           # Characters per request
EDGE_MAX_CONCURRENCY=12          # Parallel requests (HF: 1)
EDGE_MAX_SEGMENT_SECONDS=85      # Max audio segment duration
CHAPTER_PARALLEL_COUNT=0         # 0 = auto-detect from CPU cores
```

### Engine Fallback Thresholds

```bash
EDGE_MIN_CHARS_PER_SECOND=45     # Slow-mode trigger (HF: 100)
EDGE_SLOW_RATIO_THRESHOLD=2.5    # Elapsed/estimated ratio trigger (HF: 1.5)
_CHAPTER_TIMEOUT_MAX=300         # Max timeout per chapter (HF: 120s)
```

### Oversized Chapter Handling

```bash
MAX_CHAPTER_CHARS=0              # Skip chapters larger than N chars (0 = disabled)
                                  # Auto-warns when a chapter is >5× median size
```

### Local Engines

```bash
KOKORO_MAX_WORKERS=0             # 0 = auto-detect from CPU
PIPER_MAX_PROCS=0                # 0 = auto-detect from CPU
```

---

## Development

```bash
mise run test           # Full suite: Python + web lint + build
mise run test:unit      # Python unit tests only
mise run test:web       # Web lint + tests + build
mise run clean          # Remove pycache, output, job metadata
mise run trim-log       # Trim conversions.jsonl to last 500 entries
mise run hooks-test     # Validate Claude Code hook scripts
mise run audit          # Scan Python dependencies for CVEs
```

---

## TTS Engine Details

| Engine | Languages | Quality | Speed | Requires |
|--------|-----------|---------|-------|----------|
| **Edge-TTS** | All | ⭐⭐⭐ | Fastest | Internet |
| **Kokoro** | EN, JA, ZH | ⭐⭐⭐ | Fast | `espeak-ng` |
| **Piper** | All | ⭐⭐ | Moderate | ONNX model file |

**Fallback chain (CLI):** Edge multilingual → Edge monolingual → Kokoro → Piper
**Fallback chain (web):** Edge → Kokoro → Piper (ranked by live telemetry)

---

## Available Voices

### Edge-TTS (pt-BR)
- **Female**: Francisca, Brenda, Elza, Giovanna, Leila, Leticia, Manuela, Yara, Thalita
- **Male**: Antonio, Donato, Fabio, Humberto, Julio, Nicolau, Valerio

### Piper (local, pt-BR)
- `pt_BR-faber-medium` (recommended)
- `pt_BR-edresson-low`

---

## Project Structure

```
Epub-to-Mp3/
├── hf_app.py               # HF Spaces entry point (serves React + FastAPI)
├── requirements.txt
├── Dockerfile
├── mise.toml               # Task runner (install, test, web, clean, audit…)
├── python_app/
│   ├── main.py             # CLI entry point
│   ├── server.py           # FastAPI server
│   ├── src/
│   │   ├── config.py           # ConversionConfig dataclass
│   │   ├── converter.py        # CLI conversion (8 mixin classes)
│   │   ├── ebook_reader.py     # EPUB/PDF parsing, TOC hierarchy
│   │   ├── cache_manager.py    # Per-chapter text cache (.cache/)
│   │   ├── job_manager.py      # Async job queue (.jobs/)
│   │   ├── routes_health.py    # /api/health* and /system/* routes
│   │   ├── routes_sessions.py  # /api/sessions routes
│   │   ├── routes_uploads.py   # /api/uploads routes
│   │   └── tts/
│   │       ├── edge_engine.py
│   │       ├── kokoro_engine.py
│   │       └── piper_engine.py
│   └── tests/              # 1076+ tests
├── web/                    # React/TypeScript frontend (Vite)
│   └── src/
│       ├── hooks/useConversionFlow.ts
│       ├── services/ConversionService.ts
│       └── i18n/translations.ts
├── scripts/                # Benchmark and utility scripts
└── .claude/
    ├── settings.json       # Claude Code hooks config
    └── hooks/              # SessionStart, UserPromptSubmit, PostToolUse, Stop
```

---

## HF Spaces

The Space runs via Docker. GitHub CI syncs code → HF rebuilds the image.

Key auto-applied settings when `SPACE_ID` is set:
- `EDGE_MAX_CONCURRENCY=1`, `CHAPTER_PARALLEL_MAX=1` (shared CPU)
- `EDGE_MIN_CHARS_PER_SECOND=100`, `_CHAPTER_TIMEOUT_MAX=120s`
- `COMPLETED_JOB_TTL_HOURS=48` (outputs survive overnight on `/data`)

Persistent storage at `/data/epub-to-mp3/` survives Space restarts.

---

## License

MIT
