"""Tests for persistent conversion checkpoints (#4)."""

from __future__ import annotations

import importlib.util
import json
import unittest
from unittest.mock import MagicMock

import pytest

# ---------------------------------------------------------------------------
# CLI path — converter._save_conversion_checkpoint / _checkpoint_done_set
# ---------------------------------------------------------------------------


class TestConverterCheckpoint:
    """Test the AudioConverter checkpoint save/load cycle."""

    def _make_converter(self, tmp_path):
        from python_app.src.cache_manager import CacheManager
        from python_app.src.converter import AudioConverter

        conv = AudioConverter.__new__(AudioConverter)
        conv.cache_manager = CacheManager(cache_dir=tmp_path)
        conv.verbose = False
        conv._checkpoint_done_set = set()
        conv._checkpoint_total = 10
        conv._checkpoint_interval = 5
        conv._current_book_path = tmp_path / "book.epub"
        conv._current_book_path.write_bytes(b"fake")
        return conv

    def _make_config(self, output_dir):
        config = MagicMock()
        config.engine = "edge"
        config.voice = "en-US-JennyNeural"
        config.book_title = "Test Book"
        config.output_dir = str(output_dir)
        config.extra = {}
        config.force_reprocess = False
        return config

    def test_checkpoint_saved_at_interval(self, tmp_path):
        conv = self._make_converter(tmp_path)
        output_dir = tmp_path / "output"
        output_dir.mkdir()
        config = self._make_config(output_dir)

        # Complete 5 chapters → should trigger save
        for i in range(1, 6):
            # Fake _setup_temp_directory to avoid real computation
            conv._setup_temp_directory = lambda c: tmp_path / "temp"
            (tmp_path / "temp").mkdir(exist_ok=True)
            conv._save_conversion_checkpoint(i, output_dir, config, success=True)

        ckpt = conv.cache_manager.load_checkpoint(conv._current_book_path)
        assert ckpt is not None
        assert sorted(ckpt.completed_chapters) == [1, 2, 3, 4, 5]

    def test_failed_chapter_not_added_to_checkpoint(self, tmp_path):
        conv = self._make_converter(tmp_path)
        output_dir = tmp_path / "output"
        output_dir.mkdir()
        config = self._make_config(output_dir)

        conv._setup_temp_directory = lambda c: tmp_path / "temp"
        (tmp_path / "temp").mkdir(exist_ok=True)
        # success=False → should not be added
        conv._save_conversion_checkpoint(1, output_dir, config, success=False)
        assert 1 not in conv._checkpoint_done_set

    def test_checkpoint_not_saved_below_interval(self, tmp_path):
        conv = self._make_converter(tmp_path)
        output_dir = tmp_path / "output"
        output_dir.mkdir()
        config = self._make_config(output_dir)
        conv._setup_temp_directory = lambda c: tmp_path / "temp"
        (tmp_path / "temp").mkdir(exist_ok=True)

        # Only 3 chapters < interval of 5
        for i in range(1, 4):
            conv._save_conversion_checkpoint(i, output_dir, config, success=True)

        ckpt = conv.cache_manager.load_checkpoint(conv._current_book_path)
        assert ckpt is None

    def test_checkpoint_saved_at_total(self, tmp_path):
        """Checkpoint is also saved when count == total_chapters."""
        conv = self._make_converter(tmp_path)
        conv._checkpoint_total = 3
        conv._checkpoint_interval = 10  # interval > total
        output_dir = tmp_path / "output"
        output_dir.mkdir()
        config = self._make_config(output_dir)
        conv._setup_temp_directory = lambda c: tmp_path / "temp"
        (tmp_path / "temp").mkdir(exist_ok=True)

        for i in range(1, 4):
            conv._save_conversion_checkpoint(i, output_dir, config, success=True)

        ckpt = conv.cache_manager.load_checkpoint(conv._current_book_path)
        assert ckpt is not None
        assert len(ckpt.completed_chapters) == 3

    def test_checkpoint_cleared_on_success(self, tmp_path):
        conv = self._make_converter(tmp_path)
        # Save a checkpoint manually
        conv.cache_manager.save_checkpoint(
            book_path=conv._current_book_path,
            book_title="Test",
            output_dir=tmp_path / "out",
            temp_dir=tmp_path / "temp",
            total_chapters=5,
            completed_chapters=[1, 2, 3, 4, 5],
            current_chapter=5,
            conversion_config={},
        )
        assert conv.cache_manager.load_checkpoint(conv._current_book_path) is not None
        conv.cache_manager.clear_checkpoint(conv._current_book_path)
        assert conv.cache_manager.load_checkpoint(conv._current_book_path) is None


# ---------------------------------------------------------------------------
# Web path — _write_progress_checkpoint / _preload_existing_outputs
# ---------------------------------------------------------------------------

if importlib.util.find_spec("fastapi") is None:
    raise unittest.SkipTest("fastapi not installed")

from python_app import server  # noqa: E402


class TestWebProgressCheckpoint:
    def test_write_progress_checkpoint_creates_file(self, tmp_path):
        job = {
            "jobId": "test-job",
            "chaptersTotal": 5,
            "engine": "edge",
            "voice": "en-US-JennyNeural",
            "chapterProgress": [{"index": i, "status": "completed"} for i in range(1, 4)],
        }
        server._write_progress_checkpoint("test-job", job, tmp_path)
        ckpt_file = tmp_path / server._PROGRESS_CHECKPOINT_NAME
        assert ckpt_file.exists()
        data = json.loads(ckpt_file.read_text())
        assert data["job_id"] == "test-job"
        assert set(data["completed_indices"]) == {1, 2, 3}
        assert data["last_completed"] == 3

    def test_write_progress_checkpoint_skipped_chapters_included(self, tmp_path):
        job = {
            "jobId": "j1",
            "chaptersTotal": 3,
            "engine": "edge",
            "voice": "",
            "chapterProgress": [
                {"index": 1, "status": "completed"},
                {"index": 2, "status": "skipped"},
                {"index": 3, "status": "processing"},
            ],
        }
        server._write_progress_checkpoint("j1", job, tmp_path)
        data = json.loads((tmp_path / server._PROGRESS_CHECKPOINT_NAME).read_text())
        # index 3 is still processing → not in checkpoint
        assert set(data["completed_indices"]) == {1, 2}

    @pytest.mark.asyncio
    async def test_preload_uses_checkpoint_fast_path(self, tmp_path, monkeypatch):
        """When checkpoint exists, only probe listed indices."""
        from src.ebook_reader import Chapter

        chapters = [
            Chapter(index=i, name=f"Ch {i}", text="hello", source_path="") for i in range(1, 4)
        ]

        # Write MP3 files for chapters 1 and 2
        for i in [1, 2]:
            mp3 = tmp_path / f"{i:03d} - Ch {i}.mp3"
            mp3.write_bytes(b"\xff\xfb" * 1000)

        # Write checkpoint that says chapters 1 and 2 are done
        ckpt = {
            "completed_indices": [1, 2],
            "last_completed": 2,
        }
        (tmp_path / server._PROGRESS_CHECKPOINT_NAME).write_text(json.dumps(ckpt), encoding="utf-8")

        # Patch _get_audio_duration to avoid actual ffprobe
        async def _fake_duration(path):
            return 30.0

        monkeypatch.setattr(server, "_get_audio_duration", _fake_duration)

        job = {
            "jobId": "j1",
            "engine": "edge",
            "chapterProgress": [
                {"index": i, "name": f"Ch {i}", "status": "queued"} for i in range(1, 4)
            ],
        }
        outputs, completed = await server._preload_existing_outputs(job, chapters, tmp_path)
        assert completed == {1, 2}
        assert len(outputs) == 2

    @pytest.mark.asyncio
    async def test_preload_falls_back_when_no_checkpoint(self, tmp_path, monkeypatch):
        """Without a checkpoint, scan all chapters."""
        from src.ebook_reader import Chapter

        chapters = [
            Chapter(index=i, name=f"Ch {i}", text="hello", source_path="") for i in range(1, 4)
        ]
        # Only chapter 1 has an MP3
        (tmp_path / "001 - Ch 1.mp3").write_bytes(b"\xff\xfb" * 500)

        async def _fake_duration(path):
            return 15.0

        monkeypatch.setattr(server, "_get_audio_duration", _fake_duration)

        job = {
            "jobId": "j2",
            "engine": "edge",
            "chapterProgress": [
                {"index": i, "name": f"Ch {i}", "status": "queued"} for i in range(1, 4)
            ],
        }
        outputs, completed = await server._preload_existing_outputs(job, chapters, tmp_path)
        assert completed == {1}
        assert len(outputs) == 1
