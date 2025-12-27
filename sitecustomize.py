"""Automatically activate the local virtualenv for any Python process run from the repo root."""

from __future__ import annotations

import os
import sys
from pathlib import Path


def _resolve_venv_dir(repo_root: Path) -> Path:
    preferred = repo_root / ".venv"
    fallback = repo_root / ".venv311"
    if preferred.exists():
        return preferred
    return fallback


def _should_skip() -> bool:
    if os.environ.get("EPUB_MP3_SKIP_AUTO_VENV"):
        return True
    prefix = Path(sys.prefix).resolve()
    env_dir = _resolve_venv_dir(Path(__file__).resolve().parent)
    try:
        if prefix == env_dir.resolve() or env_dir in prefix.parents:
            return True
    except FileNotFoundError:
        return False
    return False


def _activate_local_venv() -> None:
    if _should_skip():
        return

    repo_root = Path(__file__).resolve().parent
    venv_dir = _resolve_venv_dir(repo_root)
    candidates = []
    if os.name == "nt":
        candidates.append(venv_dir / "Scripts" / "activate_this.py")
    candidates.append(venv_dir / "bin" / "activate_this.py")

    for script in candidates:
        if not script.exists():
            continue
        try:
            code = script.read_text()
            exec(compile(code, str(script), "exec"), {"__file__": str(script)})
            os.environ.setdefault("VIRTUAL_ENV", str(venv_dir))
            return
        except Exception:
            continue


_activate_local_venv()
