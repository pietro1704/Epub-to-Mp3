#!/usr/bin/env python3
"""Print the most recently modified directory under output/."""

import sys
from pathlib import Path

output_root = Path("output")
if not output_root.is_dir():
    sys.exit(0)

candidates = [p for p in output_root.iterdir() if p.is_dir()]
if not candidates:
    sys.exit(0)

candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
print(candidates[0])
