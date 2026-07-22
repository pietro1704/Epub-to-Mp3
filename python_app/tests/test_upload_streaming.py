from __future__ import annotations

import hashlib
from pathlib import Path

import pytest

from python_app.src.upload_streaming import (
    UploadTooLarge,
    hash_file_incremental,
    stream_upload_to_path,
)


class FakeUpload:
    def __init__(self, chunks: list[bytes]):
        self._chunks = iter(chunks)
        self.read_sizes: list[int] = []

    async def read(self, size: int = -1) -> bytes:
        self.read_sizes.append(size)
        try:
            chunk = next(self._chunks)
        except StopIteration:
            return b""
        return chunk if size < 0 else chunk[:size]


@pytest.mark.asyncio
async def test_stream_upload_writes_and_hashes_incrementally(tmp_path: Path) -> None:
    target = tmp_path / "book.epub"
    upload = FakeUpload([b"abc", b"def", b""])

    digest, size = await stream_upload_to_path(upload, target, max_bytes=6, chunk_size=3)

    assert target.read_bytes() == b"abcdef"
    assert size == 6
    assert digest == hashlib.sha1(b"abcdef").hexdigest()
    assert upload.read_sizes == [3, 3, 1]


@pytest.mark.asyncio
async def test_stream_upload_stops_at_limit_and_does_not_keep_oversize_payload(
    tmp_path: Path,
) -> None:
    target = tmp_path / "too-large.epub"
    upload = FakeUpload([b"abcd", b"efgh"])

    with pytest.raises(UploadTooLarge):
        await stream_upload_to_path(upload, target, max_bytes=5, chunk_size=4)

    assert not target.exists()
    assert upload.read_sizes == [4, 2]


def test_hash_file_incremental_does_not_read_entire_file(tmp_path: Path, monkeypatch) -> None:
    target = tmp_path / "book.epub"
    target.write_bytes(b"abcdefgh")
    original_open = Path.open
    read_sizes: list[int] = []

    def tracking_open(self: Path, *args, **kwargs):
        handle = original_open(self, *args, **kwargs)
        if self == target:
            original_read = handle.read

            def read(size: int = -1):
                read_sizes.append(size)
                return original_read(size)

            handle.read = read
        return handle

    monkeypatch.setattr(Path, "open", tracking_open)
    assert hash_file_incremental(target, chunk_size=3) == hashlib.sha1(b"abcdefgh").hexdigest()
    assert read_sizes
    assert all(size > 0 and size < len(b"abcdefgh") for size in read_sizes[:-1])
    assert read_sizes[-1] > 0  # bounded EOF probe, not an unbounded read
