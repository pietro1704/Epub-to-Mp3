from __future__ import annotations

import os
from pathlib import Path
from types import SimpleNamespace

import pytest

from python_app.src import ios_entrypoints
from python_app.src import paths as paths_module
from python_app.src.ebook_reader import Book, Chapter, EpubParser
from python_app.src.tts import _edge_transport, _piper_transport

FIXTURE_EPUB = Path(__file__).parent / "fixtures" / "epubs" / "test_multifeature.epub"


_PATHS_SNAPSHOT_ATTRS = (
    "PERSISTENT_ROOT",
    "CACHE_DIR",
    "OUTPUT_DIR",
    "JOBS_DIR",
    "UPLOADS_DIR",
    "JOB_INPUTS_DIR",
    "SOURCE_BACKUPS_DIR",
    "LOGS_DIR",
    "TELEMETRY_DIR",
)

_ENV_SNAPSHOT_KEYS = (
    "CACHE_DIR",
    "OUTPUT_DIR",
    "PERSISTENT_ROOT",
    "MAX_CHAPTER_CHARS",
    "EDGE_FIRST_CHUNK_CHARS",
    "IOS_EDGE_CHUNK_CHARS",
    "EDGE_MAX_SEGMENT_SECONDS",
    "EXPECTED_WPM",
)


@pytest.fixture(autouse=True)
def _isolate_ios_entrypoints_state():
    """Every test gets a clean transport, env, and ``paths`` module.

    ``convert_epub`` mutates ``os.environ`` and the in-memory
    ``python_app.src.paths`` module to point cache/output at iOS sandbox
    dirs. Without this fixture those mutations leak into adjacent tests
    -- notably ``test_paths.py`` which calls ``importlib.reload`` and
    sees the leftover env. We snapshot before each test and restore
    after.
    """
    env_snapshot = {k: os.environ.get(k) for k in _ENV_SNAPSHOT_KEYS}
    paths_snapshot = {a: getattr(paths_module, a, None) for a in _PATHS_SNAPSHOT_ATTRS}
    try:
        yield
    finally:
        _edge_transport.reset_transport()
        _piper_transport.reset_transport()
        for key, value in env_snapshot.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        for attr, value in paths_snapshot.items():
            if value is None:
                if hasattr(paths_module, attr):
                    delattr(paths_module, attr)
            else:
                setattr(paths_module, attr, value)


@pytest.fixture
def _fake_transport():
    """Install a deterministic byte-emitting transport for the duration
    of one test. Returns the list of (text, voice) call tuples so
    assertions can verify chunking + voice plumbing.
    """
    calls: list[tuple[str, str]] = []

    def fake(text: str, voice: str) -> bytes:
        calls.append((text, voice))
        # Emit enough bytes per chunk to clear iOS's 5KB sanity check
        # without bloating the test fixture. Pattern is recognisable in
        # hex dumps if the test ever needs forensic debugging.
        return b"FAKEMP3:" + b"X" * 600 + b":" + text[:8].encode("utf-8")

    _edge_transport.set_transport(fake)
    return calls


__all__ = [
    "Book",
    "Chapter",
    "EpubParser",
    "FIXTURE_EPUB",
    "Path",
    "SimpleNamespace",
    "_ENV_SNAPSHOT_KEYS",
    "_PATHS_SNAPSHOT_ATTRS",
    "_edge_transport",
    "_fake_transport",
    "_isolate_ios_entrypoints_state",
    "_piper_transport",
    "ios_entrypoints",
    "os",
    "paths_module",
    "pytest",
]
