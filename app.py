#!/usr/bin/env python3
"""
Hugging Face Space: EPUB to MP3 Converter
FastAPI backend for converting ebooks to audiobooks.
"""
import sys
from pathlib import Path

# Add python_app to path
sys.path.insert(0, str(Path(__file__).parent / "python_app"))

from python_app.server import app

if __name__ == "__main__":
    import uvicorn
    import os
    port = int(os.getenv("PORT", 7860))
    uvicorn.run(app, host="0.0.0.0", port=port)
