from __future__ import annotations

import sys
from pathlib import Path

# Ensure `src` package (inside python_app) is importable when running from repo root.
_PACKAGE_ROOT = Path(__file__).resolve().parent
if str(_PACKAGE_ROOT) not in sys.path:
    sys.path.insert(0, str(_PACKAGE_ROOT))

from python_app.version import __version__  # noqa: E402

__all__ = ["__version__"]
