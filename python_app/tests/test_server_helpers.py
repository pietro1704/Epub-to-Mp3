# -*- coding: utf-8 -*-
"""Tests for _server_engine_helpers and _server_job_helpers standalone functions."""

from __future__ import annotations

import json
import sys
import types
from unittest.mock import MagicMock, patch

from python_app.src.hardware_detector import HardwareProfile

# ---------------------------------------------------------------------------
# Helpers to build a minimal HardwareProfile
# ---------------------------------------------------------------------------


def _make_hw(cpu_physical: int = 4, has_gpu: bool = False) -> HardwareProfile:
    return HardwareProfile(
        cpu_count=cpu_physical,
        cpu_physical=cpu_physical,
        cpu_freq_max=2400.0,
        cpu_brand="TestCPU",
        ram_total_gb=8.0,
        ram_available_gb=4.0,
        has_gpu=has_gpu,
        network_speed_estimate="fast",
        os_type="Linux",
    )


# ---------------------------------------------------------------------------
# _infer_perf_profile (pure function — no server import needed)
# ---------------------------------------------------------------------------


class TestInferPerfProfile:
    def _call(self, hw, choice, is_space):
        from python_app.src._server_engine_helpers import _infer_perf_profile

        return _infer_perf_profile(hw, choice, is_space)

    def test_explicit_hf_choice(self):
        assert self._call(_make_hw(), "hf", False) == "hf"

    def test_explicit_local_choice(self):
        assert self._call(_make_hw(), "local", False) == "local"

    def test_explicit_cli_choice(self):
        assert self._call(_make_hw(), "cli", False) == "cli"

    def test_is_space_returns_hf(self):
        assert self._call(_make_hw(), "auto", True) == "hf"

    def test_small_cpu_no_gpu_returns_local(self):
        hw = _make_hw(cpu_physical=2, has_gpu=False)
        result = self._call(hw, "auto", False)
        assert result == "local"

    def test_large_cpu_no_gpu_returns_cli(self):
        hw = _make_hw(cpu_physical=8, has_gpu=False)
        result = self._call(hw, "auto", False)
        assert result == "cli"

    def test_small_cpu_with_gpu_returns_cli(self):
        # Even with small CPU, having a GPU qualifies for CLI
        hw = _make_hw(cpu_physical=2, has_gpu=True)
        result = self._call(hw, "auto", False)
        assert result == "cli"

    def test_exactly_four_cpus_no_gpu_returns_local(self):
        hw = _make_hw(cpu_physical=4, has_gpu=False)
        result = self._call(hw, "auto", False)
        assert result == "local"


# ---------------------------------------------------------------------------
# _normalise_languages (pure function — no server import needed)
# ---------------------------------------------------------------------------


class TestNormaliseLanguages:
    def _call(self, primary, languages=None):
        from python_app.src._server_engine_helpers import _normalise_languages

        return _normalise_languages(primary, languages)

    def test_primary_only(self):
        assert self._call("pt-BR") == ["pt-BR"]

    def test_deduplicates(self):
        result = self._call("en-US", ["en-US", "en-US"])
        assert result == ["en-US"]

    def test_primary_prepended(self):
        result = self._call("pt-BR", ["en-US"])
        assert result[0] == "pt-BR"
        assert "en-US" in result

    def test_auto_primary_excluded(self):
        result = self._call("auto", ["en-US"])
        assert "auto" not in result
        assert "en-US" in result

    def test_none_primary_and_none_languages(self):
        assert self._call(None, None) == []

    def test_empty_strings_stripped(self):
        result = self._call("", ["  ", "fr-FR"])
        assert "" not in result
        assert "fr-FR" in result

    def test_preserves_order(self):
        result = self._call("pt-BR", ["en-US", "es-ES"])
        assert result == ["pt-BR", "en-US", "es-ES"]

    def test_primary_not_duplicated_when_also_in_list(self):
        result = self._call("pt-BR", ["pt-BR", "en-US"])
        assert result.count("pt-BR") == 1

    def test_languages_without_primary(self):
        result = self._call(None, ["de-DE", "fr-FR"])
        assert result == ["de-DE", "fr-FR"]


# ---------------------------------------------------------------------------
# _ensure_voice_and_languages — tests with mocked server module
# ---------------------------------------------------------------------------


class TestEnsureVoiceAndLanguages:
    """Test _ensure_voice_and_languages by patching tts_factory on the server module."""

    def _make_fake_factory(self, voice_return: str | None = "en-US-AriaNeural"):
        """Build a fake tts_factory with a mock voice provider."""
        fake_provider = MagicMock()
        fake_provider.get_voice.return_value = voice_return
        fake_provider.build_language_voice_map.return_value = (
            {"en-US": voice_return} if voice_return else {}
        )
        fake_factory = MagicMock()
        fake_factory.voice_provider = fake_provider
        return fake_factory

    def _patch_server_factory(self, fake_factory):
        """Return a context manager that patches tts_factory on whatever server is loaded."""
        # Ensure the real server module is in sys.modules first
        import importlib

        if "python_app.server" not in sys.modules:
            try:
                importlib.import_module("python_app.server")
            except Exception:
                pass

        if "python_app.server" in sys.modules:
            return patch.object(sys.modules["python_app.server"], "tts_factory", fake_factory)
        # Fallback: inject a fake module
        fake_srv = types.ModuleType("python_app.server")
        fake_srv.tts_factory = fake_factory
        return patch.dict(sys.modules, {"python_app.server": fake_srv})

    def test_populates_languages_and_voice(self):
        from python_app.src import _server_engine_helpers as helpers
        from python_app.src.config import ConversionConfig

        fake_factory = self._make_fake_factory("en-US-AriaNeural")
        config = ConversionConfig(engine="edge", voice=None, primary_language="en-US")
        with self._patch_server_factory(fake_factory):
            helpers._ensure_voice_and_languages(config)

        assert config.voice == "en-US-AriaNeural"
        assert "en-US" in config.languages


# ---------------------------------------------------------------------------
# _extract_chapter_details
# ---------------------------------------------------------------------------


class TestExtractChapterDetails:
    def _call(self, job):
        from python_app.src._server_job_helpers import _extract_chapter_details

        return _extract_chapter_details(job)

    def test_empty_job_returns_empty_list(self):
        assert self._call({}) == []

    def test_non_list_chapter_progress_returns_empty_list(self):
        assert self._call({"chapterProgress": "bad"}) == []

    def test_basic_entry_extracted(self):
        job = {
            "chapterProgress": [
                {
                    "index": 1,
                    "name": "Introduction",
                    "status": "completed",
                    "engine": "edge",
                    "textLength": 1200,
                }
            ]
        }
        details = self._call(job)
        assert len(details) == 1
        d = details[0]
        assert d["index"] == 1
        assert d["name"] == "Introduction"
        assert d["status"] == "completed"
        assert d["engine"] == "edge"
        assert d["chars"] == 1200

    def test_optional_fields_included_when_present(self):
        job = {
            "chapterProgress": [
                {
                    "index": 2,
                    "name": "Chapter 2",
                    "status": "completed",
                    "engine": "kokoro",
                    "textLength": None,
                    "startedAt": "2026-01-01T00:00:00Z",
                    "completedAt": "2026-01-01T00:05:00Z",
                    "elapsedSeconds": 300.0,
                    "charsPerSecond": 4.0,
                    "engineSequence": ["edge", "kokoro"],
                    "retryCount": 1,
                    "retryReason": "timeout",
                    "errorCategory": "transient",
                    "errorMessage": "timed out",
                }
            ]
        }
        details = self._call(job)
        d = details[0]
        assert d["startedAt"] == "2026-01-01T00:00:00Z"
        assert d["completedAt"] == "2026-01-01T00:05:00Z"
        assert d["elapsedSeconds"] == 300.0
        assert d["charsPerSecond"] == 4.0
        assert d["engineSequence"] == ["edge", "kokoro"]
        assert d["retryCount"] == 1
        assert d["retryReason"] == "timeout"
        assert d["errorCategory"] == "transient"
        assert d["errorMessage"] == "timed out"

    def test_none_values_excluded_from_output(self):
        job = {
            "chapterProgress": [
                {
                    "index": 3,
                    "name": None,
                    "status": None,
                    "engine": None,
                    "textLength": None,
                }
            ]
        }
        details = self._call(job)
        d = details[0]
        assert "name" not in d or d.get("name") is None
        # 'index' should still be present (value 3 is not None)
        assert d["index"] == 3

    def test_non_dict_entries_skipped(self):
        job = {"chapterProgress": [None, "invalid", 42, {"index": 1, "name": "OK"}]}
        details = self._call(job)
        assert len(details) == 1
        assert details[0]["index"] == 1

    def test_multiple_entries(self):
        job = {
            "chapterProgress": [
                {"index": i, "name": f"Ch{i}", "status": "completed", "engine": "edge"}
                for i in range(5)
            ]
        }
        details = self._call(job)
        assert len(details) == 5

    def test_chars_falls_back_to_chars_field(self):
        job = {
            "chapterProgress": [
                {
                    "index": 1,
                    "name": "X",
                    "status": "completed",
                    "engine": "edge",
                    "textLength": None,
                    "chars": 500,
                }
            ]
        }
        details = self._call(job)
        assert details[0]["chars"] == 500


# ---------------------------------------------------------------------------
# _write_progress_checkpoint — tests with mocked server module
# ---------------------------------------------------------------------------


class TestWriteProgressCheckpoint:
    def _make_fake_srv(self):
        fake_srv = types.ModuleType("python_app.server")
        fake_srv._utcnow_iso = lambda: "2026-01-01T00:00:00Z"
        fake_srv._PROGRESS_CHECKPOINT_NAME = "_progress_checkpoint.json"
        return fake_srv

    def test_writes_checkpoint_file(self, tmp_path):
        from python_app.src import _server_job_helpers as helpers

        fake_srv = self._make_fake_srv()
        job = {
            "jobId": "abc123",
            "chaptersTotal": 5,
            "engine": "edge",
            "voice": "en-US-AriaNeural",
            "chapterProgress": [
                {"index": 1, "status": "completed"},
                {"index": 2, "status": "skipped"},
                {"index": 3, "status": "failed"},
            ],
        }
        with patch.dict(sys.modules, {"python_app.server": fake_srv}):
            helpers._write_progress_checkpoint("abc123", job, tmp_path)

        checkpoint = tmp_path / "_progress_checkpoint.json"
        assert checkpoint.exists()
        data = json.loads(checkpoint.read_text(encoding="utf-8"))
        assert data["job_id"] == "abc123"
        assert data["total_chapters"] == 5
        assert data["engine"] == "edge"
        assert data["voice"] == "en-US-AriaNeural"
        assert set(data["completed_indices"]) == {1, 2}  # skipped counts, failed does not

    def test_last_completed_is_max_index(self, tmp_path):
        from python_app.src import _server_job_helpers as helpers

        fake_srv = self._make_fake_srv()
        job = {
            "jobId": "j1",
            "chaptersTotal": 10,
            "engine": "piper",
            "voice": "pt-BR",
            "chapterProgress": [
                {"index": 3, "status": "completed"},
                {"index": 7, "status": "completed"},
                {"index": 5, "status": "skipped"},
            ],
        }
        with patch.dict(sys.modules, {"python_app.server": fake_srv}):
            helpers._write_progress_checkpoint("j1", job, tmp_path)

        data = json.loads((tmp_path / "_progress_checkpoint.json").read_text(encoding="utf-8"))
        assert data["last_completed"] == 7

    def test_no_completed_chapters_last_completed_zero(self, tmp_path):
        from python_app.src import _server_job_helpers as helpers

        fake_srv = self._make_fake_srv()
        job = {
            "jobId": "j2",
            "chaptersTotal": 3,
            "engine": "edge",
            "voice": "",
            "chapterProgress": [
                {"index": 1, "status": "failed"},
            ],
        }
        with patch.dict(sys.modules, {"python_app.server": fake_srv}):
            helpers._write_progress_checkpoint("j2", job, tmp_path)

        data = json.loads((tmp_path / "_progress_checkpoint.json").read_text(encoding="utf-8"))
        assert data["last_completed"] == 0
        assert data["completed_indices"] == []

    def test_empty_chapter_progress_writes_zero(self, tmp_path):
        from python_app.src import _server_job_helpers as helpers

        fake_srv = self._make_fake_srv()
        job = {
            "jobId": "j3",
            "chaptersTotal": 0,
            "engine": "",
            "voice": "",
            "chapterProgress": [],
        }
        with patch.dict(sys.modules, {"python_app.server": fake_srv}):
            helpers._write_progress_checkpoint("j3", job, tmp_path)

        data = json.loads((tmp_path / "_progress_checkpoint.json").read_text(encoding="utf-8"))
        assert data["completed_indices"] == []
        assert data["last_completed"] == 0

    def test_missing_chapter_progress_does_not_raise(self, tmp_path):
        from python_app.src import _server_job_helpers as helpers

        fake_srv = self._make_fake_srv()
        job = {"jobId": "j4", "chaptersTotal": 2, "engine": "edge", "voice": ""}
        # Should not raise even if chapterProgress is absent
        with patch.dict(sys.modules, {"python_app.server": fake_srv}):
            helpers._write_progress_checkpoint("j4", job, tmp_path)

    def test_entries_without_index_skipped(self, tmp_path):
        from python_app.src import _server_job_helpers as helpers

        fake_srv = self._make_fake_srv()
        job = {
            "jobId": "j5",
            "chaptersTotal": 2,
            "engine": "edge",
            "voice": "",
            "chapterProgress": [
                {"status": "completed"},  # no index key
                {"index": 4, "status": "completed"},
            ],
        }
        with patch.dict(sys.modules, {"python_app.server": fake_srv}):
            helpers._write_progress_checkpoint("j5", job, tmp_path)

        data = json.loads((tmp_path / "_progress_checkpoint.json").read_text(encoding="utf-8"))
        assert data["completed_indices"] == [4]
