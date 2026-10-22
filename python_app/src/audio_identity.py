"""Streaming audio digests, bounded SHA-256 reuse and duplicate identity checks."""

from __future__ import annotations

import asyncio
import hashlib
import threading
from collections import OrderedDict
from pathlib import Path
from typing import Optional

from .chapter_utils import MIN_DUPLICATE_CHARS


def _hash_audio_file(path: Path) -> str:
    hasher = hashlib.sha1()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def _hash_text_payload(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8", errors="ignore")).hexdigest()


# ---------------------------------------------------------------------------
# MP3 SHA-256 for client-side verification
#
# The iOS client (and any future official client) verifies downloaded chapter
# audio against the SHA-256 advertised by the backend.  Recomputing the digest
# on every job-status read is expensive (chapter MP3s can be 5–50 MB), so we
# memoise by (absolute path, mtime, size).  The cache is bounded (LRU) so a
# long-lived server process cannot grow it unboundedly, and it is guarded by a
# lock because both the SSE broadcaster and the conversion worker may race
# on the same path right after a chapter finishes.
# ---------------------------------------------------------------------------

class Mp3DigestCache:
    """Own the bounded digest cache and its synchronization."""

    def __init__(self):
        self.entries: "OrderedDict[tuple[str, int, int], str]" = OrderedDict()
        self.lock = threading.Lock()

    def compute(self, path: Path, max_entries: int) -> str:
        """Return the hex SHA-256 digest of *path*, with an LRU cache.

        Cache key is ``(absolute path, mtime_ns, size)``: any of these changing
        invalidates the cached digest.  Reads in 8 KB chunks so very large MP3s
        do not blow up memory.  Caller is responsible for handling the IO/FS
        error surface — this helper lets exceptions bubble.
        """
        path = Path(path)
        stat_result = path.stat()
        key = (str(path.resolve()), stat_result.st_mtime_ns, stat_result.st_size)

        with self.lock:
            cached = self.entries.get(key)
            if cached is not None:
                # Mark as recently used.
                self.entries.move_to_end(key)
                return cached

        hasher = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(8192), b""):
                hasher.update(chunk)
        digest = hasher.hexdigest()

        with self.lock:
            self.entries[key] = digest
            self.entries.move_to_end(key)
            while len(self.entries) > max_entries:
                self.entries.popitem(last=False)

        return digest

    def clear(self) -> None:
        with self.lock:
            self.entries.clear()


# Duplicate tracker


class AudioDuplicateTracker:
    def __init__(self) -> None:
        self._hashes: dict[str, dict] = {}
        self._lock = asyncio.Lock()

    async def check_duplicate(
        self,
        audio_path: Path,
        text: str,
        chapter_index: int,
        chapter_name: str,
    ) -> Optional[dict]:
        text_len = len(text or "")
        if text_len < MIN_DUPLICATE_CHARS:
            return None
        text_hash = _hash_text_payload(text)
        audio_hash = _hash_audio_file(audio_path)
        async with self._lock:
            existing = self._hashes.get(audio_hash)
            if (
                existing
                and existing.get("text_hash") != text_hash
                and existing.get("text_len", 0) >= MIN_DUPLICATE_CHARS
            ):
                return existing
            self._hashes[audio_hash] = {
                "index": chapter_index,
                "name": chapter_name,
                "text_hash": text_hash,
                "text_len": text_len,
            }
        return None
