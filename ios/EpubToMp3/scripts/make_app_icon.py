#!/usr/bin/env python3
"""Compatibility entry point for the shared app-icon exporter."""
import os
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[3]
os.execvp("ruby", ["ruby", str(root / "scripts/export_app_icons.rb"), *sys.argv[1:]])
