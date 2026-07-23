"""Bounded-memory upload streaming and incremental file hashing helpers."""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import BinaryIO, Protocol


class UploadTooLarge(ValueError):
    """Raised when an upload exceeds its configured byte limit."""


class AsyncReadable(Protocol):
    async def read(self, size: int = -1) -> bytes: ...


async def stream_upload_to_path(
    upload: AsyncReadable,
    destination: Path,
    *,
    max_bytes: int = 0,
    chunk_size: int = 1024 * 1024,
) -> tuple[str | None, int]:
    """Write *upload* to disk while hashing and enforcing *max_bytes*.

    Reads are bounded to ``chunk_size`` and, when a limit is configured, to
    the remaining allowance plus one byte.  That extra byte lets the helper
    reject an oversize payload without buffering or writing it.  A rejected
    destination is removed so callers never observe a partial upload.
    """
    if chunk_size <= 0:
        raise ValueError("chunk_size must be positive")
    destination = Path(destination)
    hasher = hashlib.sha1()
    total = 0
    try:
        with destination.open("wb") as handle:
            while True:
                if max_bytes:
                    remaining = max_bytes - total
                    if remaining < 0:
                        raise UploadTooLarge
                    read_size = min(chunk_size, remaining + 1)
                else:
                    read_size = chunk_size
                chunk = await upload.read(read_size)
                if not chunk:
                    break
                if max_bytes and len(chunk) > max_bytes - total:
                    raise UploadTooLarge
                handle.write(chunk)
                hasher.update(chunk)
                total += len(chunk)
    except UploadTooLarge:
        destination.unlink(missing_ok=True)
        raise
    except BaseException:
        destination.unlink(missing_ok=True)
        raise
    return (hasher.hexdigest() if total else None), total


def hash_file_incremental(
    handle: BinaryIO,
    *,
    chunk_size: int = 1024 * 1024,
) -> str:
    """Return a SHA-1 digest without loading the file into memory.

    The caller owns path validation and opens the already-approved file.
    """
    if chunk_size <= 0:
        raise ValueError("chunk_size must be positive")
    hasher = hashlib.sha1()
    for chunk in iter(lambda: handle.read(chunk_size), b""):
        hasher.update(chunk)
    return hasher.hexdigest()
