# -*- coding: utf-8 -*-
"""Persistent (disk) TOC cache tests added in v0.3.24."""

from __future__ import annotations

import json

import pytest
import src.ebook_reader as ebook_reader
from src.ebook_reader import (
    TocItem,
    _toc_cache_get,
    _toc_cache_put,
    _toc_disk_cache_path,
    _toc_from_jsonable,
    _toc_to_jsonable,
)


@pytest.fixture(autouse=True)
def _isolate_caches(tmp_path, monkeypatch):
    # Redirect the disk-cache root so the test never touches the real cache.
    monkeypatch.setattr(ebook_reader, "_toc_cache", type(ebook_reader._toc_cache)())

    class _FakeCacheDir:
        def __init__(self, base):
            self._base = base

        def __truediv__(self, other):
            return self._base / other

        def __str__(self):
            return str(self._base)

        def __fspath__(self):
            return str(self._base)

    fake_cache = tmp_path / "cache"
    fake_cache.mkdir()
    monkeypatch.setattr("src.paths.CACHE_DIR", _FakeCacheDir(fake_cache), raising=False)
    yield


def _items() -> list:
    return [
        TocItem(
            title="Chapter 1",
            href="ch1.xhtml",
            level=1,
            children=[
                TocItem(title="1.1", href="ch1.xhtml#sec1", level=2, children=[]),
            ],
        ),
        TocItem(title="Chapter 2", href="ch2.xhtml", level=1, children=[]),
    ]


def test_jsonable_roundtrip_preserves_hierarchy():
    original = _items()
    payload = _toc_to_jsonable(original)
    restored = _toc_from_jsonable(payload)
    assert len(restored) == 2
    assert restored[0].title == "Chapter 1"
    assert len(restored[0].children) == 1
    assert restored[0].children[0].title == "1.1"
    assert restored[0].children[0].level == 2


def test_disk_cache_persists_across_inmem_eviction(tmp_path):
    # Create a fake EPUB-like file so os.stat returns a real mtime_ns.
    epub_path = tmp_path / "book.epub"
    epub_path.write_bytes(b"PK\x03\x04")

    items = _items()
    _toc_cache_put(str(epub_path), None, items)

    disk_path = _toc_disk_cache_path(str(epub_path))
    assert disk_path is not None and disk_path.exists()
    payload = json.loads(disk_path.read_text(encoding="utf-8"))
    assert payload["mtime_ns"] > 0
    assert len(payload["toc"]) == 2

    # Wipe the in-memory LRU; next get must hit disk.
    ebook_reader._toc_cache.clear()
    restored = _toc_cache_get(str(epub_path), None)
    assert restored is not None
    assert [it.title for it in restored] == ["Chapter 1", "Chapter 2"]


def test_disk_cache_invalidates_on_mtime_change(tmp_path):
    epub_path = tmp_path / "book.epub"
    epub_path.write_bytes(b"PK\x03\x04")
    _toc_cache_put(str(epub_path), None, _items())
    ebook_reader._toc_cache.clear()
    # Tamper the cached mtime so the persistent cache no longer matches.
    disk_path = _toc_disk_cache_path(str(epub_path))
    assert disk_path is not None
    payload = json.loads(disk_path.read_text(encoding="utf-8"))
    payload["mtime_ns"] = 1
    disk_path.write_text(json.dumps(payload), encoding="utf-8")
    assert _toc_cache_get(str(epub_path), None) is None
