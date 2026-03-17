from __future__ import annotations

import pytest

# Import from canonical source modules to avoid cross-test contamination from
# tests that patch sys.modules["python_app.server"] with fake modules.
from python_app.src._server_audio_helpers import AudioDuplicateTracker
from python_app.src.chapter_utils import MIN_DUPLICATE_CHARS


@pytest.mark.asyncio
async def test_audio_duplicate_tracker_flags_duplicate(tmp_path):
    tracker = AudioDuplicateTracker()
    payload = b"mock-audio-data" * 5

    audio_a = tmp_path / "chapter-1.mp3"
    audio_b = tmp_path / "chapter-2.mp3"
    audio_a.write_bytes(payload)
    audio_b.write_bytes(payload)

    min_len = max(1, int(MIN_DUPLICATE_CHARS))
    text_a = "a" * (min_len + 10)
    text_b = "b" * (min_len + 10)

    first = await tracker.check_duplicate(audio_a, text_a, 1, "Capitulo 1")
    assert first is None

    duplicate = await tracker.check_duplicate(audio_b, text_b, 2, "Capitulo 2")
    assert duplicate is not None
    assert duplicate["index"] == 1
