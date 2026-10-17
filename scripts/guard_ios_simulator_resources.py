#!/usr/bin/env python3
"""Compatibility entry point retained for existing mise tasks."""

from __future__ import annotations

import sys


def main() -> int:
    # Kept as a no-op while existing mise tasks still invoke this script.
    return 0


if __name__ == "__main__":
    sys.exit(main())
