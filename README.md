# EPUB to MP3 Converter

Convert EPUB/PDF ebooks into MP3 audiobooks using TTS engines.

**Live Demo**: [Hugging Face Space](https://huggingface.co/spaces/pi1704/epub-to-mp3)

## Features

- **TTS Engines**: Edge-TTS (online), Coqui TTS, Piper (local)
- **Portuguese BR Voices**: High-quality curated voices
- **Smart Cache**: Resume interrupted conversions
- **Chapter Structure**: Preserves book navigation hierarchy
- **Progress Tracking**: Real-time ETA and status
- **Footnote Handling**: Inline, chapter-end, or suppressed
- **Interactive Menu**: Pick engine/voice/settings interactively

## Installation

```bash
# Clone repository
git clone https://github.com/pietro1704/Epub-to-Mp3.git
cd Epub-to-Mp3

# Install dependencies
pip install -r requirements.txt

# System dependency: FFmpeg
# Ubuntu/Debian: sudo apt install ffmpeg
# macOS: brew install ffmpeg
```

## CLI Usage

```bash
# Basic conversion
python -m python_app.main book.epub

# With specific voice
python -m python_app.main book.epub --engine edge --voice pt-BR-FranciscaNeural

# Interactive menu
python -m python_app.main book.epub --menu

# Single chapter
python -m python_app.main book.epub --chapter 3

# Skip footnotes
python -m python_app.main book.epub --no-footnote

# Show structure only
python -m python_app.main book.epub --show-structure

# Clear cache and reprocess
python -m python_app.main book.epub --clear-cache
```

## API Server

```bash
# Start FastAPI server
python app.py

# Or via uvicorn
uvicorn app:app --host 0.0.0.0 --port 8000
```

### API Endpoints

- `POST /api/convert` - Upload EPUB and start conversion
- `GET /api/jobs/{job_id}` - Check conversion status
- `GET /api/outputs/{job_id}/{filename}` - Download output file
- `GET /api/health` - Health check

## Available Voices

### Edge-TTS (PT-BR)
- **Female**: Francisca, Brenda, Elza, Giovanna, Leila, Leticia, Manuela, Yara
- **Male**: Antonio, Donato, Fabio, Humberto, Julio, Nicolau, Valerio

### Piper (Local)
- `pt_BR-faber-medium` (recommended)
- `pt_BR-edresson-low`

## Project Structure

```
Epub-to-Mp3/
├── app.py              # HF Space entry point (FastAPI)
├── requirements.txt    # Dependencies
├── python_app/
│   ├── main.py         # CLI entry point
│   ├── server.py       # FastAPI server
│   ├── models/         # Piper ONNX models
│   ├── src/
│   │   ├── config.py
│   │   ├── converter.py
│   │   ├── ebook_reader.py
│   │   ├── cache_manager.py
│   │   └── tts/        # TTS engine implementations
│   └── tests/
└── .github/workflows/  # CI + HF sync
```

## License

MIT
