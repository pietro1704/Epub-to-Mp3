# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Project Overview

EPUB/PDF to MP3 audiobook converter using TTS engines (Edge-TTS, Coqui, Piper). Includes FastAPI server for Hugging Face Space deployment.

## Commands

### Setup
```bash
# Requires Python 3.11 (for Coqui TTS compatibility)
python3.11 -m venv .venv311
source .venv311/bin/activate
pip install -r requirements.txt
# FFmpeg required: brew install ffmpeg (macOS) or apt install ffmpeg (Linux)
```

### CLI Usage
```bash
python -m python_app.main book.epub                    # Basic
python -m python_app.main book.epub --menu             # Interactive
python -m python_app.main book.epub --engine edge      # Edge-TTS
python -m python_app.main book.epub --chapter 3        # Single chapter
python -m python_app.main book.epub --show-structure   # Preview
```

### API Server
```bash
python app.py                                          # HF Space entry
uvicorn python_app.server:app --port 8000              # Direct server
```

### Testing
```bash
pytest -v --tb=short
```

## Architecture

```
python_app/
├── main.py           # CLI entry point
├── server.py         # FastAPI server
├── models/           # Piper ONNX models
└── src/
    ├── config.py           # Dataclass configuration
    ├── converter.py        # Conversion logic
    ├── ebook_reader.py     # EPUB/PDF parsing
    ├── cache_manager.py    # Smart caching
    └── tts/
        ├── factory.py      # TTS engine factory
        ├── edge_engine.py  # Microsoft Edge-TTS
        ├── coqui_engine.py # Coqui TTS (local)
        └── piper_engine.py # Piper (local ONNX)
```

### Design Patterns
- **Factory Pattern**: TTSFactory creates engine instances
- **Dataclass Config**: Centralized settings in ConversionConfig
- **Intelligent Caching**: `.cache/Book_Title/` for parsed text

### Key Limits
- Edge-TTS: 8000 chars/chunk
- Coqui/Piper: 1500 chars/chunk
- Audio: 22050Hz, 32k bitrate, mono

## Guidelines
- Follow existing factory pattern for new TTS engines
- Preserve chapter structure from EPUB navigation
- Validate dependencies before engine use
- Keep changes minimal and focused
- Confirm changes before implementation
