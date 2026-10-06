"""Tests for the iOS development-book staging helper."""

from __future__ import annotations

import importlib.util
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "seed_ios_development_book.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("seed_ios_development_book", SCRIPT)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def test_explicit_seed_source_takes_precedence_over_legacy_configuration(
    monkeypatch, tmp_path
) -> None:
    module = _load_module()
    source = tmp_path / "book.epub"
    legacy = tmp_path / "legacy.epub"
    source.write_bytes(b"epub")
    legacy.write_bytes(b"legacy")
    monkeypatch.setenv("IOS_DEVELOPMENT_SEED_SOURCE", str(source))
    monkeypatch.setenv("IOS_DEVELOPMENT_SEED_BOOK", str(legacy))

    assert module.development_book_source() == source


def test_boolean_seed_flag_is_not_treated_as_a_source_path(monkeypatch, tmp_path) -> None:
    module = _load_module()
    (tmp_path / "1").write_bytes(b"not a book")
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(module.Path, "home", lambda: tmp_path)
    monkeypatch.delenv("IOS_DEVELOPMENT_SEED_SOURCE", raising=False)
    monkeypatch.setenv("IOS_DEVELOPMENT_SEED_BOOK", "1")

    assert module.development_book_source() is None
