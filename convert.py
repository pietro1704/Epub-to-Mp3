#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Convenience wrapper for python_app.main"""
import sys
from pathlib import Path

# Add python_app to path so 'src' imports work
project_root = Path(__file__).parent
sys.path.insert(0, str(project_root / "python_app"))

from python_app.main import main

if __name__ == "__main__":
    # Auto-inject 'convert' subcommand if first arg is not a known subcommand
    if len(sys.argv) > 1 and sys.argv[1] not in ['convert', 'menu', 'clear-cache', '-h', '--help']:
        sys.argv.insert(1, 'convert')

    # Expand ~ in file paths
    import os
    for i, arg in enumerate(sys.argv):
        if arg.startswith('~'):
            sys.argv[i] = os.path.expanduser(arg)

    sys.exit(main())
