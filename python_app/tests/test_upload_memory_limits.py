"""Regression tests for bounded multipart upload handling."""

from __future__ import annotations

import asyncio
import hashlib
from pathlib import Path

import pytest
from fastapi import HTTPException
from src.routes_uploads import _sha1_file, _stream_upload_to_path


class _ChunkedUpload:
    def __init__(self, chunks: list[bytes]) -> None:
        self._chunks = iter(chunks)
        self.read_sizes: list[int] = []

    async def read(self, size: int = -1) -> bytes:
        self.read_sizes.append(size)
        return next(self._chunks, b"")


def test_stream_upload_writes_incrementally_and_returns_hash_and_size(tmp_path: Path) -> None:
    chunks = [b"first", b"second", b"third"]
    upload = _ChunkedUpload(chunks)
    destination = tmp_path / "book.epub"

    result = asyncio.run(_stream_upload_to_path(upload, destination, max_bytes=100))

    assert destination.read_bytes() == b"firstsecondthird"
    assert result == {
        "size": 16,
        "sha1": hashlib.sha1(b"firstsecondthird").hexdigest(),
    }
    assert upload.read_sizes
    assert all(0 < size <= 1024 * 1024 for size in upload.read_sizes)


def test_stream_upload_rejects_at_limit_without_retaining_partial_file(tmp_path: Path) -> None:
    upload = _ChunkedUpload([b"1234", b"56"])
    destination = tmp_path / "too-large.epub"

    with pytest.raises(HTTPException) as error:
        asyncio.run(_stream_upload_to_path(upload, destination, max_bytes=5))

    assert error.value.status_code == 413
    assert not destination.exists()


def test_sha1_file_reads_local_source_incrementally(tmp_path: Path, monkeypatch) -> None:
    source = tmp_path / "local.epub"
    payload = b"local upload contents"
    source.write_bytes(payload)

    def fail_read_bytes(_self):
        raise AssertionError("local upload hashing must not retain the whole file")

    monkeypatch.setattr(Path, "read_bytes", fail_read_bytes)

    assert _sha1_file(source) == hashlib.sha1(payload).hexdigest()
