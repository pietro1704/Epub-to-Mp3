---
title: EPUB to MP3 Audiobook Converter
emoji: 📚
colorFrom: blue
colorTo: purple
sdk: docker
pinned: false
---

# 📚 EPUB to MP3 Audiobook Converter

Convert your EPUB/PDF ebooks into MP3 audiobooks with natural Portuguese Brazilian voices.

## Features

- 🎙️ **15 Natural Portuguese Voices** (Microsoft Edge-TTS)
- 📖 **EPUB & PDF Support**
- 🎵 **Optimized MP3 Output** (8kbps, ideal for audiobooks)
- 🚀 **Fast Processing**
- 📱 **Modern Web Interface**

## Usage

1. Upload your EPUB or PDF file
2. Select a Brazilian Portuguese voice
3. Click "Convert to Audiobook"
4. Download your MP3 files

## Limitations

- Large files may take a few minutes to process
- ~100MB file size limit
- Portuguese language only

## Tech Stack

- **Frontend**: React + TypeScript + Vite
- **Backend**: FastAPI + Python
- **TTS**: Microsoft Edge-TTS
- **Deployment**: Hugging Face Spaces

## Local Development

```bash
# Install dependencies
pip install -r requirements-hf.txt
cd web && npm install && npm run build && cd ..

# Run server
python hf_app.py

# Open http://localhost:7860
```

## License

MIT License
