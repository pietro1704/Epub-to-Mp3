#!/usr/bin/env python3
"""List EPUB/PDF files in a directory sorted by size ascending."""

import sys
from pathlib import Path

src = Path(sys.argv[1])
files = [p for p in src.iterdir() if p.suffix.lower() in {".epub", ".pdf"}]
files.sort(key=lambda p: p.stat().st_size)
for p in files:
    print(p.name)
