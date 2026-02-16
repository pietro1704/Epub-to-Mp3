#!/usr/bin/env python3
"""
Hugging Face Space: EPUB to MP3 Converter
FastAPI backend for converting ebooks to audiobooks.
"""

import os
import sys
from pathlib import Path

# Auto-accept Coqui TTS license (CPML non-commercial) before any import
os.environ.setdefault("COQUI_TOS_AGREED", "1")

# Add python_app to path
sys.path.insert(0, str(Path(__file__).parent / "python_app"))

from python_app.server import app

if __name__ == "__main__":
    import os

    import uvicorn

    port = int(os.getenv("PORT", 7860))
    uvicorn.run(app, host="0.0.0.0", port=port)
