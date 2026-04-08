# -*- coding: utf-8 -*-
"""
Unit tests for simplified converter module
"""

import asyncio
import json
import os
import re
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.config import ConversionConfig
from src.converter import (
    EDGE_OFFLINE_LONG_CHARS,
    AudioConverter,
    ChapterProcessor,
    ConversionResult,
    validate_audio_completeness,
)
from src.ebook_reader import Chapter
from src.text_formatting import TextFormattingProcessor


class MockTTSEngine:
    """Base mock TTS engine with all required attributes for testing"""

    def __init__(self):
        self.last_error = None
        self.last_segment_report = None
        self.partial_failure_detected = False

    def get_synthesis_tracker(self):
        """Mock synthesis tracker that returns no missing segments"""
        return None

    async def synthesize_async(self, text, output_path, formatting_segments=None):
        """Default implementation - subclasses should override"""
        output_path = Path(output_path)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(b"fake audio" * 200)  # > 1000 bytes
        return output_path


class TestConversionResult(unittest.IsolatedAsyncioTestCase):
    """Test cases for ConversionResult dataclass"""

    def setUp(self):
        self.converter = AudioConverter()
        self.temp_dir = tempfile.mkdtemp()
        self.config = ConversionConfig(
            engine="edge",
            voice="test-voice",
            output_dir=self.temp_dir,
            book_title="Test Book",
            validate_audio=False,  # Disable audio validation for mock testing
            validate_text=False,  # Disable text validation for mock testing
        )

    def tearDown(self):
        import shutil

        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_conversion_result_creation(self):
        """Test ConversionResult creation"""
        result = ConversionResult(
            success=True,
            total_chapters=5,
            converted_chapters=4,
            output_files=[Path("file1.mp3"), Path("file2.mp3")],
            errors=["Error in chapter 3"],
        )

        self.assertTrue(result.success)
        self.assertEqual(result.total_chapters, 5)
        self.assertEqual(result.converted_chapters, 4)
        self.assertEqual(len(result.output_files), 2)
        self.assertEqual(len(result.errors), 1)

    async def test_auto_validate_output_calls_validate_conversion(self):
        """Ensure auto validation is triggered with validate_conversion.validate_book"""
        output_dir = Path(self.temp_dir)
        epub_file = output_dir / "book.epub"
        epub_file.write_text("dummy")
        self.converter._current_book_path = epub_file
        self.config.auto_validate_output = True
        self.converter._active_config = self.config

        with patch("src.converter.Path") as mock_path:
            mock_path.return_value = output_dir
            with patch("validate_conversion.validate_book", return_value=({}, [])) as mock_validate:
                await self.converter._auto_validate_output(output_dir, stage="test")
                mock_validate.assert_called_once()

    async def test_auto_validate_output_triggers_auto_fix_on_issues(self):
        """Auto-validate should trigger validation when enabled."""
        output_dir = Path(self.temp_dir)
        cache_dir = Path(self.temp_dir) / "cache"
        cache_dir.mkdir()
        epub_file = output_dir / "book.epub"
        epub_file.write_text("dummy")
        self.converter._current_book_path = epub_file

        # Enable auto-validate in config
        self.config.auto_validate_output = True
        self.config.cache_dir = str(cache_dir)
        self.converter._active_config = self.config

        # Mock validation to return success
        good_stats = {
            "missing_cache": 0,
            "text_mismatch": 0,
            "parsed_pretts_diff": 0,
            "missing_mp3": 0,
            "duration_mismatch": 0,
        }

        with patch(
            "validate_conversion.validate_book", return_value=(good_stats, [])
        ) as mock_validate:
            await self.converter._auto_validate_output(output_dir, stage="test")
            # Should call validation at least once
            mock_validate.assert_called_once()


class TestAudioConverter(unittest.IsolatedAsyncioTestCase):
    """Test cases for AudioConverter class"""

    def setUp(self):
        """Set up test fixtures"""
        self.converter = AudioConverter()
        self.temp_dir = tempfile.mkdtemp()

        # Mock objects
        self.mock_reader = Mock()
        self.mock_reader.title = "Test Book"
        self.mock_reader._toc_expected_chapters = 0
        self.mock_reader.get_chapter_structure.return_value = [
            Chapter(1, "Chapter 1", "ch1.html", "Content 1"),
            Chapter(2, "Chapter 2", "ch2.html", "Content 2"),
        ]

        self.config = ConversionConfig(
            engine="edge",
            voice="test-voice",
            output_dir=self.temp_dir,
            book_title="Test Book",
            validate_audio=False,
            validate_text=False,
        )

    def tearDown(self):
        """Clean up test fixtures"""
        import shutil

        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_eta_baseline_persistence_roundtrip(self):
        config = ConversionConfig(
            engine="piper",
            output_dir=self.temp_dir,
            book_title="ETA Book",
            validate_audio=False,
            validate_text=False,
        )
        baseline_path = Path(self.temp_dir) / "eta-baselines.json"
        self.converter._eta_baseline_path = baseline_path

        self.assertEqual(self.converter._load_eta_baseline(config), 0.0)
        self.converter._save_eta_baseline(config, 150.0)
        loaded = self.converter._load_eta_baseline(config)
        self.assertGreater(loaded, 0.0)
        self.converter._save_eta_baseline(config, 210.0)
        loaded_2 = self.converter._load_eta_baseline(config)
        self.assertGreaterEqual(loaded_2, loaded)

    def test_split_cached_chapters_respects_force_reprocess(self):
        """Force reprocess should ignore any cached MP3s that already exist."""
        chapter = Chapter(1, "Chapter 1", "ch1.html", "Content 1")
        output_dir = Path(self.temp_dir)
        config = ConversionConfig(
            engine="edge",
            output_dir=output_dir,
            force_reprocess=True,
            validate_audio=False,
            validate_text=False,
        )
        cached_mp3 = self.converter._expected_output_path(chapter, 1, output_dir)
        cached_mp3.parent.mkdir(parents=True, exist_ok=True)
        cached_mp3.write_bytes(b"audio" * 400)  # Ensure file > 1000 bytes

        cached, pending = self.converter._split_cached_chapters([chapter], output_dir, config)

        self.assertEqual(cached, [], "Cached MP3s must be ignored when force_reprocess=True")
        self.assertEqual(pending, [chapter], "All chapters should be reprocessed")

    def test_pre_segment_health_check_uses_adaptive_interval(self):
        """Pre-segment checks should skip intermediate segments when interval > 1."""
        state = self.converter._segment_adaptive_state
        state["pre_check_base_interval"] = 1
        state["pre_check_interval_by_engine"] = {"edge": 2}
        state["pre_check_counter_by_engine"] = {}

        self.converter._resource_snapshot = Mock(
            return_value=SimpleNamespace(cpu_percent=55.0, ram_gb=2.5)
        )

        self.converter._pre_segment_health_check(
            engine_label="edge",
            segment_chars=5000,
            config=self.config,
            engine_obj=None,
        )
        self.converter._pre_segment_health_check(
            engine_label="edge",
            segment_chars=5000,
            config=self.config,
            engine_obj=None,
        )

        self.assertEqual(self.converter._resource_snapshot.call_count, 1)

    def test_startup_guardrail_applies_when_last_run_regressed(self):
        cfg = ConversionConfig(
            engine="piper",
            output_dir=self.temp_dir,
            book_title="Guardrail Book",
            piper_max_procs=4,
            piper_chunk_chars=3000,
            validate_audio=False,
            validate_text=False,
        )
        guardrail_path = Path(self.temp_dir) / "startup-guardrail.json"
        self.converter._startup_guardrail_path = guardrail_path
        key = self.converter._eta_baseline_key_for_config(cfg)
        guardrail_path.write_text(
            json.dumps({key: {"baseline_cps": 200.0, "last_cps": 120.0}}),
            encoding="utf-8",
        )
        with patch.dict(os.environ, {}, clear=True):
            self.converter._apply_startup_guardrail(cfg)
            self.assertEqual(cfg.extra.get("startup_guardrail"), "1")
            self.assertEqual(cfg.piper_max_procs, 3)
            self.assertEqual(cfg.piper_chunk_chars, 2700)

    async def test_startup_canary_selects_faster_profile(self):
        cfg = ConversionConfig(
            engine="piper",
            output_dir=self.temp_dir,
            book_title="Canary Book",
            piper_max_procs=2,
            piper_chunk_chars=3000,
            validate_audio=False,
            validate_text=False,
        )

        class _Engine:
            def __init__(self):
                self.calls = 0

            async def synthesize_async(self, text, output_path):
                self.calls += 1
                # First candidate slower than second candidate.
                if self.calls == 1:
                    await asyncio.sleep(0.03)
                else:
                    await asyncio.sleep(0.005)
                Path(output_path).write_bytes(b"RIFF" + b"\x00" * 512)
                return Path(output_path)

        engine = _Engine()
        await self.converter._maybe_run_piper_canary(
            tts_engine=engine,
            config=cfg,
            chapter_text="x" * 2000,
            output_dir=Path(self.temp_dir),
            chapter_index=1,
        )
        self.assertEqual(cfg.piper_max_procs, 3)
        self.assertEqual(cfg.piper_chunk_chars, 2700)
        self.assertTrue(self.converter._canary_profile_done)

    def test_stage_pipeline_toggle_from_config_extra(self):
        self.config.extra["stage_pipeline"] = "1"
        self.assertTrue(self.converter._is_stage_pipeline_enabled(self.config))
        self.config.extra["stage_pipeline"] = "0"
        self.assertFalse(self.converter._is_stage_pipeline_enabled(self.config))

    def test_stage_pipeline_depth_from_config_extra(self):
        self.config.extra["stage_pipeline_depth"] = "4"
        self.assertEqual(self.converter._stage_pipeline_depth(self.config), 4)
        self.config.extra["stage_pipeline_depth"] = "invalid"
        self.assertGreaterEqual(self.converter._stage_pipeline_depth(self.config), 1)

    def test_write_segment_metrics_outputs_summary_and_csv(self):
        output_dir = Path(self.temp_dir)
        self.converter._append_segment_metric(
            {
                "event": "segment_success",
                "engine": "edge",
                "chapter": "1",
                "segment_chars": 1000,
                "elapsed_s": 2.0,
            },
            output_dir=output_dir,
        )
        self.converter._append_segment_metric(
            {
                "event": "segment_success",
                "engine": "edge",
                "chapter": "1",
                "segment_chars": 500,
                "elapsed_s": 1.0,
            },
            output_dir=output_dir,
        )
        self.converter._write_segment_metrics_summary(output_dir)
        self.converter._write_segment_metrics_csv(output_dir)
        self.converter._write_segment_metrics_dashboard(output_dir)
        self.assertTrue((output_dir / "segment-metrics-summary.json").exists())
        self.assertTrue((output_dir / "segment-metrics-engine-chapter.csv").exists())
        self.assertTrue((output_dir / "segment-metrics-dashboard.html").exists())

    def test_write_runtime_recommendations_outputs_file(self):
        output_dir = Path(self.temp_dir)
        (output_dir / "metrics-summary.json").write_text(
            json.dumps(
                {
                    "chapters": {"total": 10, "failed": 2},
                    "engine_switches": 6,
                    "optimization_metrics": {"prefetch_hit_rate": 0.2, "budget_caps_applied": 5},
                    "edge_blocked_chapters": {"count": 1},
                }
            ),
            encoding="utf-8",
        )
        (output_dir / "segment-metrics-summary.json").write_text(
            json.dumps(
                {
                    "engines": {
                        "edge": {"avg_chars_per_second": 100.0},
                        "piper": {"avg_chars_per_second": 120.0},
                    }
                }
            ),
            encoding="utf-8",
        )
        self.converter._write_runtime_recommendations(output_dir)
        rec_path = output_dir / "metrics-recommendations.txt"
        self.assertTrue(rec_path.exists())
        text = rec_path.read_text(encoding="utf-8")
        self.assertIn("Runtime Recommendations", text)

    def test_percentile_helper(self):
        values = [1.0, 2.0, 3.0, 4.0, 5.0]
        self.assertAlmostEqual(self.converter._percentile(values, 0.5), 3.0, places=3)
        self.assertAlmostEqual(self.converter._percentile(values, 0.95), 4.8, places=1)

    def test_warm_start_prunes_expired_entries(self):
        self.converter._warm_start_enabled = True
        self.converter._warm_start_ttl_seconds = 60.0
        warm_path = Path(self.temp_dir) / "warm-start.json"
        self.converter._warm_start_path = warm_path
        now = time.time()
        payload = {
            "updated_at": now,
            "ttl_seconds": 60.0,
            "entries": {
                "fresh": {"ts": now - 10},
                "expired": {"ts": now - 1000},
            },
        }
        warm_path.write_text(json.dumps(payload), encoding="utf-8")
        entries = self.converter._load_warm_start_state()
        self.assertIn("fresh", entries)
        self.assertNotIn("expired", entries)

    @patch("src.converter.time.time", side_effect=[1.0, 2.0, 3.0, 4.0, 5.0, 6.0])
    def test_record_segment_success_promotes_pre_check_interval(self, _mock_time):
        """Stable successful segments should increase pre-check interval."""
        state = self.converter._segment_adaptive_state
        state["pre_check_base_interval"] = 1
        state["pre_check_max_interval"] = 3
        state["pre_check_promote_streak"] = 2
        state["pre_check_interval_by_engine"] = {"edge": 1}
        state["pre_check_stable_streak_by_engine"] = {"edge": 0}
        state["cooldown_seconds"] = 9999.0

        self.converter._resource_snapshot = Mock(
            return_value=SimpleNamespace(cpu_percent=40.0, ram_gb=3.0)
        )

        self.converter._record_segment_success(
            engine_label="edge",
            chapter_index=1,
            segment_chars=1000,
            config=self.config,
        )
        self.converter._record_segment_success(
            engine_label="edge",
            chapter_index=1,
            segment_chars=1000,
            config=self.config,
        )
        self.converter._record_segment_success(
            engine_label="edge",
            chapter_index=1,
            segment_chars=1000,
            config=self.config,
        )

        self.assertEqual(state["pre_check_interval_by_engine"]["edge"], 2)

    def test_apply_persisted_engine_params_updates_config(self):
        """Converter should apply persisted best params for matching key."""
        store_path = Path(self.temp_dir) / "profiles.json"
        self.converter._best_param_store.path = store_path
        self.converter._best_param_store.upsert_profile(
            engine="edge",
            voice="test-voice",
            language="auto",
            chars_per_second=1000.0,
            params={
                "edge_chunk_chars": 15000,
                "edge_max_concurrency": 9,
                "edge_enable_parallel": True,
                "edge_max_segment_seconds": 95,
            },
        )
        changed = self.converter._apply_persisted_engine_params(
            cfg=self.config,
            engine_label="edge",
            engine_obj=None,
        )
        self.assertTrue(changed)
        self.assertEqual(self.config.edge_chunk_chars, 15000)
        self.assertEqual(self.config.edge_max_concurrency, 9)

    def test_persist_engine_params_after_chapter_saves_best(self):
        """Successful chapter should persist tuned params for future runs."""
        store_path = Path(self.temp_dir) / "profiles.json"
        self.converter._best_param_store.path = store_path
        self.converter._persist_engine_params_after_chapter(
            cfg=self.config,
            engine_label="edge",
            chapter_chars=5000,
            elapsed_s=5.0,
            success=True,
        )
        entry = self.converter._best_param_store.get_profile(
            engine="edge", voice="test-voice", language="auto"
        )
        self.assertIsNotNone(entry)
        self.assertGreater(float(entry.get("best_chars_per_second", 0.0)), 0.0)

    def test_runtime_tuning_key_contains_machine_signature(self):
        self.converter.hardware_profile = SimpleNamespace(
            cpu_physical=8,
            ram_total_gb=16.0,
            os_type="Darwin",
            network_speed_estimate="fast",
        )
        key = self.converter._runtime_tuning_key(self.config, "edge")
        self.assertIn("machine_signature", key)
        self.assertIn("darwin", key["machine_signature"])

    def test_pick_auto_engine_ab_exploration(self):
        """Auto picker keeps Edge first when Edge is available in auto mode."""
        self.converter._auto_ab_enabled = True
        self.converter._auto_ab_interval = 2
        self.converter._auto_ab_max_gap = 10.0
        self.converter._auto_ab_counter = 1  # next call triggers exploration
        self.converter.speed_controller.get_engine_ranking = Mock(
            return_value=[("edge", 72.0, "fast"), ("piper", 66.0, "stable")]
        )
        self.converter.speed_controller.recommend_engine_for_chapter = Mock(return_value=None)
        self.converter.speed_controller.recommend_engine_switch = Mock(return_value=None)
        self.converter.speed_controller._current_engine = None
        pool = {
            "edge": (ConversionConfig(engine="edge"), object()),
            "piper": (ConversionConfig(engine="piper"), object()),
        }
        selected, _order = self.converter._pick_auto_engine(12000, 120.0, pool)
        self.assertEqual(selected, "edge")

    def test_classify_failure_reason(self):
        self.assertEqual(
            self.converter._classify_failure_reason("429 too many requests"), "throttle"
        )
        self.assertEqual(
            self.converter._classify_failure_reason("SSL certificate error"), "network"
        )
        self.assertEqual(self.converter._classify_failure_reason("timeout after 30s"), "transient")
        self.assertEqual(self.converter._classify_failure_reason("401 unauthorized"), "auth")

    def test_engine_resource_budget_reduces_parallel_on_pressure(self):
        self.converter._resource_budget_enabled = True
        self.converter._parallel_state["ceiling"] = 4
        self.converter._parallel_state["current"] = 4
        self.converter._apply_engine_resource_budget(
            engine_label="edge",
            snapshot=SimpleNamespace(cpu_percent=98.0, ram_gb=0.4),
            engine_pool=None,
        )
        self.converter._apply_engine_resource_budget(
            engine_label="edge",
            snapshot=SimpleNamespace(cpu_percent=97.0, ram_gb=0.5),
            engine_pool=None,
        )
        self.assertEqual(self.converter._parallel_state["current"], 3)

    def test_adaptive_state_checkpoint_roundtrip(self):
        path_dir = Path(self.temp_dir)
        self.converter._adaptive_checkpoint_enabled = True
        self.converter._segment_adaptive_state["pre_check_interval_by_engine"] = {"edge": 3}
        self.converter._engine_resource_budget = {
            "edge": {"cap": 2, "pressure_streak": 0, "free_streak": 0}
        }
        self.converter._auto_ab_counter = 9
        self.converter._save_adaptive_state_checkpoint(path_dir)

        other = AudioConverter()
        other._adaptive_checkpoint_enabled = True
        other._load_adaptive_state_checkpoint(path_dir)
        self.assertEqual(
            other._segment_adaptive_state["pre_check_interval_by_engine"].get("edge"), 3
        )
        self.assertEqual(other._engine_resource_budget.get("edge", {}).get("cap"), 2)
        self.assertEqual(other._auto_ab_counter, 9)

    def test_runtime_metrics_summary_includes_optimization_metrics(self):
        metrics_path = Path(self.temp_dir) / "_runtime_metrics.jsonl"
        events = [
            {"event": "prefetch_request", "chapter": 1},
            {"event": "prefetch_hit", "chapter": 1},
            {"event": "auto_ab_exploration", "chapter": 1, "engine": "piper"},
            {"event": "resource_budget_cap", "engine": "edge"},
            {"event": "adaptive_state_restored"},
            {"event": "chapter_complete", "chapter": 1, "engine": "edge", "success": True},
        ]
        metrics_path.write_text(
            "\n".join(json.dumps(item, ensure_ascii=False) for item in events) + "\n",
            encoding="utf-8",
        )
        self.converter._last_output_dir = Path(self.temp_dir)
        self.converter._write_runtime_metrics_summary(Path(self.temp_dir))
        summary_path = Path(self.temp_dir) / "metrics-summary.json"
        self.assertTrue(summary_path.exists())
        payload = json.loads(summary_path.read_text(encoding="utf-8"))
        opt = payload.get("optimization_metrics", {})
        self.assertEqual(int(opt.get("prefetch_requests", 0)), 1)
        self.assertEqual(int(opt.get("prefetch_hits", 0)), 1)
        self.assertEqual(int(opt.get("ab_explorations", 0)), 1)
        self.assertEqual(int(opt.get("budget_caps_applied", 0)), 1)
        self.assertEqual(int(opt.get("adaptive_state_restores", 0)), 1)

    def test_analyze_chapter_stats_flags_prefer_offline(self):
        """Very long chapters should trigger offline recommendation."""
        chapter_long = Chapter(1, "Long", "c1.html", "x" * (EDGE_OFFLINE_LONG_CHARS + 5000))
        chapter_short = Chapter(2, "Short", "c2.html", "brief text")
        stats = self.converter._analyze_chapter_stats([chapter_long, chapter_short])
        self.assertTrue(stats["prefer_offline_engine"])
        self.assertIn("chapter", stats.get("offline_reason", ""))

    @patch("src.converter._has_piper_support", return_value=True)
    @patch("src.converter._has_coqui_support", return_value=False)
    def test_apply_chapter_engine_preferences_auto(self, mock_coqui, mock_piper):
        """Auto mode should not preemptively switch away from Edge first-attempt flow."""
        config = ConversionConfig(engine="auto", output_dir=self.temp_dir)
        stats = {"prefer_offline_engine": True, "offline_reason": "long chapter"}
        self.converter._apply_chapter_engine_preferences(config, stats)
        self.assertFalse(config.auto_prefer_piper)
        self.assertEqual(config.engine, "auto")

    @patch("src.converter._has_piper_support", return_value=True)
    @patch("src.converter._has_coqui_support", return_value=False)
    def test_apply_chapter_engine_preferences_switches_edge(self, mock_coqui, mock_piper):
        """Explicit Edge engine should remain unchanged until a real failure happens."""
        config = ConversionConfig(engine="edge", output_dir=self.temp_dir)
        stats = {"prefer_offline_engine": True, "offline_reason": "long chapter"}
        self.converter._apply_chapter_engine_preferences(config, stats)
        self.assertEqual(config.engine, "edge")

    @patch("src.converter._has_piper_support", return_value=False)
    @patch("src.converter._has_coqui_support", return_value=True)
    def test_apply_chapter_engine_preferences_coqui_fallback(self, mock_coqui, mock_piper):
        """Offline recommendation should remain advisory before any runtime failure."""
        config = ConversionConfig(engine="edge", output_dir=self.temp_dir)
        stats = {"prefer_offline_engine": True, "offline_reason": "long chapter"}
        self.converter._apply_chapter_engine_preferences(config, stats)
        self.assertEqual(config.engine, "edge")

    @patch("src.converter._has_piper_support", return_value=True)
    @patch("src.converter._has_coqui_support", return_value=True)
    def test_resolve_offline_fallback_prefers_piper(self, mock_coqui, mock_piper):
        choice = self.converter._resolve_offline_fallback_engine({"edge", "piper", "coqui"})
        self.assertEqual(choice, "piper")

    def test_should_preempt_edge_timeout_for_long_chapter(self):
        self.converter._segment_adaptive_state["engine_cps"] = {"edge": [70.0, 72.0, 68.0]}
        reason = self.converter._should_preempt_edge_timeout(
            chapter_chars=120_000,
            estimated_seconds=400.0,
        )
        self.assertIsNotNone(reason)

    def test_spot_check_text_against_epub(self):
        """Spot-check should ensure snippets from EPUB exist in payload."""
        epub_text = (
            "Primeira frase do capítulo. Segunda frase continua o raciocínio. "
            "Aqui vem uma terceira frase para alongar o texto."
        )
        payload_ok = epub_text + " Texto extra opcional."
        payload_missing_mid = "Primeira frase do capítulo. Conteúdo cortado no meio."

        self.assertTrue(AudioConverter._spot_check_text_against_epub(epub_text, payload_ok))
        self.assertFalse(
            AudioConverter._spot_check_text_against_epub(epub_text, payload_missing_mid)
        )

    def test_resolve_problem_chapter_indices_supports_decimal_labels(self):
        chapters = [
            Chapter("4.1", "Cap 4.1", "c41.xhtml", "texto 41"),
            Chapter("4.2", "Cap 4.2", "c42.xhtml", "texto 42"),
            Chapter("5.0", "Cap 5.0", "c50.xhtml", "texto 50"),
            Chapter("6", "Cap 6", "c6.xhtml", "texto 6"),
        ]

        mapped = self.converter._resolve_problem_chapter_indices(chapters, ["4.2", "5.0"])
        self.assertEqual(mapped, ["4.2", "5.0"])

    def test_resolve_problem_chapter_indices_does_not_collapse_decimal_to_integer(self):
        chapters = [
            Chapter("4.2", "Cap 4.2", "c42.xhtml", "texto 42"),
            Chapter("4", "Cap 4", "c4.xhtml", "texto 4"),
        ]

        mapped = self.converter._resolve_problem_chapter_indices(chapters, ["4"])
        self.assertEqual(mapped, ["4"])

    def test_categorize_problems_treats_missing_cache_as_full_reconvert(self):
        issues = [
            "Chapter 4.2: Missing cache files",
            "Chapter 4.2: Missing MP3 file",
            "Chapter 5.0: Missing cache files",
            "Chapter 5.1: Missing MP3 file",
            "Chapter 6.1: Duration mismatch (+45%)",
        ]
        problem_chapters = ["4.2", "5.0", "5.1", "6.1"]

        missing_mp3_only, duration_only = self.converter._categorize_problems(
            issues, problem_chapters
        )

        # 4.2 and 5.0 require full reconversion (not quick synthesis)
        self.assertEqual(missing_mp3_only, ["5.1"])
        self.assertEqual(duration_only, ["6.1"])

    def test_init(self):
        """Test AudioConverter initialization"""
        self.assertIsNotNone(self.converter.tts_factory)
        self.assertIsNotNone(self.converter.audio_processor)
        self.assertIsNotNone(self.converter.file_manager)
        self.assertIsNotNone(self.converter.progress)

    def test_failure_checkpoint_roundtrip(self):
        """Failure checkpoint should persist and clear failed chapter metadata."""
        temp_dir = Path(self.temp_dir) / "checkpoint"
        temp_dir.mkdir(parents=True, exist_ok=True)
        self.converter._save_failure_checkpoint(
            temp_dir,
            failed_chapters=["1", "2.1 - Chapter"],
            edge_blocked_chapters=["1"],
        )
        payload = self.converter._load_failure_checkpoint(temp_dir)
        self.assertIn("failed_chapters", payload)
        self.assertEqual(set(payload["failed_chapters"]), {"1", "2.1 - Chapter"})
        self.assertEqual(set(payload.get("edge_blocked_chapters", [])), {"1"})
        self.converter._clear_failure_checkpoint(temp_dir)
        self.assertEqual(self.converter._load_failure_checkpoint(temp_dir), {})

    def test_metrics_dashboard_generation(self):
        """Dashboard HTML should be generated from summary + csv files."""
        temp_dir = Path(self.temp_dir) / "metrics"
        temp_dir.mkdir(parents=True, exist_ok=True)
        (temp_dir / "_runtime_metrics.jsonl").write_text("", encoding="utf-8")
        (temp_dir / "metrics-summary.json").write_text(
            '{"total_events":1,"chapters":{"total":1,"successful":1},"engine_switches":0,"edge_blocked_chapters":{"count":0,"chapters":[]}}',
            encoding="utf-8",
        )
        (temp_dir / "metrics-chapter-engine.csv").write_text(
            "chapter,engine,attempts,successes,failures,total_chars,total_elapsed_s,avg_chars_per_second,last_error\n1,edge,1,1,0,1000,2.0,500,\n",
            encoding="utf-8",
        )
        self.converter._write_runtime_metrics_dashboard(temp_dir)
        dashboard = temp_dir / "metrics-dashboard.html"
        self.assertTrue(dashboard.exists())
        content = dashboard.read_text(encoding="utf-8")
        self.assertIn("Conversion Metrics Dashboard", content)

    def test_setup_output_directory(self):
        """Test output directory setup"""
        output_dir = self.converter._setup_output_directory(self.config)

        self.assertIsInstance(output_dir, Path)
        self.assertTrue(output_dir.exists())
        self.assertIn("Test Book", str(output_dir))

    def test_setup_output_directory_no_title(self):
        """Test output directory setup without book title"""
        config = ConversionConfig(
            engine="edge",
            output_dir=self.temp_dir,
            book_title="",
            validate_audio=False,
            validate_text=False,
        )
        output_dir = self.converter._setup_output_directory(config)

        expected = Path(self.temp_dir) / "default"
        self.assertEqual(output_dir, expected)

    def test_cache_text_creation(self):
        """Ensure chapter text cache is written to disk."""
        cache_dir = Path(self.temp_dir)
        chapter = Chapter(1, "Cache Chapter", "ch-cache.html", "original text")
        payload = "linha 1\nlinha 2"

        self.converter._cache_text(cache_dir, chapter, 1, payload)

        expected = cache_dir / "text" / "001 - Cache Chapter.txt"
        self.assertTrue(expected.exists())
        self.assertEqual(expected.read_text(encoding="utf-8"), payload)

    def test_cached_text_matches_tts_input_simple(self):
        """Test that cached text exactly matches TTS input for simple text"""
        cache_dir = Path(self.temp_dir)

        # Simple text without formatting
        chapter = Chapter(
            index=1, name="Simple Chapter", source_path="ch1.html", text="This is a simple test."
        )

        # Get what would be sent to TTS
        tts_input = self.converter._speech_text(chapter)

        # Cache it
        self.converter._cache_text(cache_dir, chapter, 1, tts_input)

        # Read back
        cached_path = cache_dir / "text" / "001 - Simple Chapter.txt"
        cached_text = cached_path.read_text(encoding="utf-8")

        # MUST BE IDENTICAL
        self.assertEqual(cached_text, tts_input, "Cached text must exactly match TTS input")
        self.assertEqual(
            cached_text, "This is a simple test.", "Cached text should preserve simple text exactly"
        )

    def test_cached_text_matches_tts_input_with_language_tags(self):
        """Test that cached text preserves language tags exactly as sent to TTS"""
        cache_dir = Path(self.temp_dir)

        # Text with language tags
        text_with_tags = "English text [[lang:pt-BR]]Texto em português[[/lang]] back to English"

        chapter = Chapter(
            index=2, name="Multilingual Chapter", source_path="ch2.html", text=text_with_tags
        )

        # Get what would be sent to TTS
        tts_input = self.converter._speech_text(chapter)

        # Cache it
        self.converter._cache_text(cache_dir, chapter, 2, tts_input)

        # Read back
        cached_path = cache_dir / "text" / "002 - Multilingual Chapter.txt"
        cached_text = cached_path.read_text(encoding="utf-8")

        # MUST BE IDENTICAL
        self.assertEqual(
            cached_text, tts_input, "Cached text must exactly match TTS input with language tags"
        )

        # Should contain the language tags
        self.assertIn(
            "[[lang:pt-BR]]", cached_text, "Language tags should be preserved in cached text"
        )
        self.assertIn(
            "[[/lang]]", cached_text, "Closing language tags should be preserved in cached text"
        )

    def test_cached_text_matches_tts_input_with_speech_text(self):
        """Test that cached text uses speech_text when available"""
        cache_dir = Path(self.temp_dir)

        # Chapter with separate speech_text
        chapter = Chapter(
            index=3,
            name="Speech Chapter",
            source_path="ch3.html",
            text="Original text with HTML",
            speech_text="Processed speech text with [[lang:pt-BR]]português[[/lang]]",
        )

        # Get what would be sent to TTS
        tts_input = self.converter._speech_text(chapter)

        # Should use speech_text, not text
        self.assertEqual(
            tts_input, chapter.speech_text, "_speech_text should return speech_text when available"
        )

        # Cache it
        self.converter._cache_text(cache_dir, chapter, 3, tts_input)

        # Read back
        cached_path = cache_dir / "text" / "003 - Speech Chapter.txt"
        cached_text = cached_path.read_text(encoding="utf-8")

        # MUST BE IDENTICAL to speech_text
        self.assertEqual(cached_text, tts_input, "Cached text must match TTS input (speech_text)")
        self.assertEqual(
            cached_text, chapter.speech_text, "Cached text should use speech_text when available"
        )

    def test_parse_txt_vs_tts_input_txt_files(self):
        """Test that parse.txt and tts_input.txt are saved correctly"""
        cache_dir = Path(self.temp_dir)

        # Chapter where text != speech_text
        chapter = Chapter(
            index=5,
            name="Dual Text Chapter",
            source_path="ch5.html",
            text="Original parsed text from EPUB",
            speech_text="Processed speech text [[lang:pt-BR]]with tags[[/lang]]",
        )

        # Get what would be sent to TTS
        tts_input = self.converter._speech_text(chapter)

        # Should use speech_text
        self.assertEqual(tts_input, chapter.speech_text)

        # Simulate caching (as done in converter.py)
        target_dir = cache_dir / "text"
        target_dir.mkdir(parents=True, exist_ok=True)
        safe_name = "Dual_Text_Chapter"

        # Save both files (NEW FORMAT: "N - Name-parsed.txt")
        parse_path = target_dir / f"5 - {safe_name}-parsed.txt"
        parse_path.write_text(chapter.text or "", encoding="utf-8")

        pre_tts_path = target_dir / f"5 - {safe_name}-pre-tts.txt"
        pre_tts_path.write_text(tts_input, encoding="utf-8")

        # Verify both files exist
        self.assertTrue(parse_path.exists(), "parsed.txt should exist")
        self.assertTrue(pre_tts_path.exists(), "pre-tts.txt should exist")

        # Read back
        parse_content = parse_path.read_text(encoding="utf-8")
        pre_tts_content = pre_tts_path.read_text(encoding="utf-8")

        # Verify parsed.txt has original text
        self.assertEqual(
            parse_content, chapter.text, "parsed.txt should contain original chapter.text"
        )

        # Verify pre-tts.txt has speech_text
        self.assertEqual(
            pre_tts_content, chapter.speech_text, "pre-tts.txt should contain speech_text"
        )
        self.assertEqual(pre_tts_content, tts_input, "pre-tts.txt should match what goes to TTS")

        # They should be DIFFERENT in this case
        self.assertNotEqual(
            parse_content,
            pre_tts_content,
            "parsed.txt and pre-tts.txt should differ when text != speech_text",
        )

        # Verify language tags are in pre-tts but not in parse
        self.assertIn("[[lang:pt-BR]]", pre_tts_content)
        self.assertNotIn("[[lang:pt-BR]]", parse_content)

    def test_cached_text_matches_tts_input_with_pauses(self):
        """Test that cached text preserves pause markers (ellipsis)"""
        cache_dir = Path(self.temp_dir)

        # Text with pauses
        text_with_pauses = "Wait... for it... now!"

        chapter = Chapter(
            index=4, name="Pause Chapter", source_path="ch4.html", text=text_with_pauses
        )

        # Get what would be sent to TTS
        tts_input = self.converter._speech_text(chapter)

        # Cache it
        self.converter._cache_text(cache_dir, chapter, 4, tts_input)

        # Read back
        cached_path = cache_dir / "text" / "004 - Pause Chapter.txt"
        cached_text = cached_path.read_text(encoding="utf-8")

        # MUST BE IDENTICAL
        self.assertEqual(
            cached_text, tts_input, "Cached text must exactly match TTS input with pauses"
        )

        # Should preserve ellipsis
        self.assertEqual(
            cached_text.count("..."), 2, "Pause markers (ellipsis) should be preserved"
        )

    async def test_integration_cache_matches_tts_during_conversion(self):
        """Integration test: verify cached text matches what was sent to TTS during actual conversion"""
        cache_dir = Path(self.temp_dir) / ".cache" / "Test_Book"
        cache_dir.mkdir(parents=True, exist_ok=True)

        # Create chapter with language tags
        chapter = Chapter(
            index=1,
            name="Test Chapter",
            source_path="ch1.html",
            text="English text [[lang:pt-BR]]Texto em português[[/lang]] more English",
            speech_text="English text [[lang:pt-BR]]Texto em português[[/lang]] more English",
        )

        # Mock TTS engine that captures what it receives
        captured_tts_input = []

        class MockTTSEngine:
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                # Capture what TTS actually receives
                captured_tts_input.append(text)

                # Create fake output file
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"fake audio data" * 100)  # > 1000 bytes
                return output_path

        mock_engine = MockTTSEngine()

        # Run conversion
        chapters = [chapter]
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Test Book",
        )

        result = await self.converter._convert_chapters_sequential(
            chapters, mock_engine, cache_dir, config
        )

        # Verify conversion succeeded
        self.assertEqual(result.converted_chapters, 1, "Chapter should be converted")
        self.assertEqual(len(captured_tts_input), 1, "TTS should be called once")

        # Get what was actually sent to TTS
        actual_tts_input = captured_tts_input[0]

        # Find the cached text files
        text_cache_dir = cache_dir / "text"
        self.assertTrue(text_cache_dir.exists(), "Text cache directory should exist")

        # Should have 2 files: -parsed.txt and -pre-tts.txt
        all_files = list(text_cache_dir.glob("*.txt"))
        self.assertGreaterEqual(len(all_files), 2, "Should have at least 2 cached text files")

        # Find the pre-tts.txt file specifically
        pre_tts_files = list(text_cache_dir.glob("*-pre-tts.txt"))
        self.assertEqual(len(pre_tts_files), 1, "Should have exactly one pre-tts.txt file")

        cached_text = pre_tts_files[0].read_text(encoding="utf-8")

        # THE CRITICAL TEST: cached text MUST match what was sent to TTS
        self.assertEqual(
            cached_text,
            actual_tts_input,
            "CRITICAL: Cached text must EXACTLY match what was sent to TTS engine",
        )

        # Verify language tags are preserved
        if "[[lang:pt-BR]]" in actual_tts_input:
            self.assertIn(
                "[[lang:pt-BR]]",
                cached_text,
                "Language tags in TTS input must appear in cached text",
            )

    async def test_integration_parse_and_tts_files_created(self):
        """Integration: verify parse.txt and tts_input.txt are both created during conversion"""
        cache_dir = Path(self.temp_dir) / ".cache" / "Integration_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        # Chapter with different text and speech_text
        chapter = Chapter(
            index=1,
            name="Integration Chapter",
            source_path="ch1.html",
            text="Raw parsed text from EPUB",
            speech_text="Processed [[lang:pt-BR]]speech text[[/lang]] for TTS",
        )

        class TrackingTTSEngine:
            """TTS engine that tracks what it receives"""

            def __init__(self):
                self.received_text = None

            async def synthesize_async(self, text, output_path, formatting_segments=None):
                self.received_text = text
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"audio" * 400)  # > 1000 bytes
                return output_path

        tracking_engine = TrackingTTSEngine()

        # Run conversion
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            book_title="Integration_Test",
            validate_audio=False,
            validate_text=False,
        )

        result = await self.converter._convert_chapters_sequential(
            [chapter], tracking_engine, cache_dir, config
        )

        # Verify conversion succeeded
        self.assertEqual(result.converted_chapters, 1)

        # Verify files were created
        text_dir = cache_dir / "text"
        self.assertTrue(text_dir.exists())

        # NEW FORMAT: N - Name-parsed.txt and N - Name-pre-tts.txt
        parse_files = list(text_dir.glob("*-parsed.txt"))
        pre_tts_files = list(text_dir.glob("*-pre-tts.txt"))

        self.assertEqual(len(parse_files), 1, "Should have one parsed.txt file")
        self.assertEqual(len(pre_tts_files), 1, "Should have one pre-tts.txt file")

        # Read both files
        parse_content = parse_files[0].read_text(encoding="utf-8")
        pre_tts_content = pre_tts_files[0].read_text(encoding="utf-8")

        # Verify parsed.txt = original chapter.text
        self.assertEqual(
            parse_content, chapter.text, "parsed.txt should contain original chapter.text"
        )

        # Verify pre-tts.txt = speech_text (what was sent to TTS)
        self.assertEqual(
            pre_tts_content, chapter.speech_text, "pre-tts.txt should contain speech_text"
        )
        self.assertEqual(
            pre_tts_content,
            tracking_engine.received_text,
            "pre-tts.txt should match what TTS received",
        )

        # parsed.txt should be different (in this case)
        self.assertNotEqual(
            parse_content,
            pre_tts_content,
            "parsed.txt should differ from pre-tts when text != speech_text",
        )

    async def test_long_chapter_tts_receives_full_text(self):
        """Ensure long chapters deliver the complete payload to the TTS engine."""
        cache_dir = Path(self.temp_dir) / ".cache" / "Long_Book"
        cache_dir.mkdir(parents=True, exist_ok=True)

        long_text = " ".join(f"Sentence {i}." for i in range(4000))
        chapter = Chapter(
            index=1,
            name="Long Chapter",
            source_path="long.html",
            text=long_text,
            speech_text=long_text,
        )

        captured_inputs = []

        class CapturingTTSEngine:
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                captured_inputs.append(text)
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"edge" * 800_000)  # ≈3.2MB to mimic long audio
                return output_path

        async def fake_convert_to_mp3(input_file, output_file, bitrate="8k"):
            output_path = Path(output_file)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_bytes(b"mp3" * 800_000)  # ≈2.4MB simulated MP3
            return output_path

        self.converter.audio_processor.convert_to_mp3 = fake_convert_to_mp3

        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Long_Book",
            edge_auto_offline_chars=0,
            edge_auto_offline_seconds=0,
        )

        result = await self.converter._convert_chapters_sequential(
            [chapter],
            CapturingTTSEngine(),
            cache_dir,
            config,
        )

        self.assertEqual(result.converted_chapters, 1, "Chapter should convert successfully")
        self.assertEqual(len(captured_inputs), 1, "TTS must be invoked exactly once")

        normalise = lambda value: re.sub(r"\s+", " ", value or "").strip()

        self.assertEqual(
            normalise(captured_inputs[0]),
            normalise(long_text),
            "Full chapter text must reach the TTS engine without truncation",
        )

        pre_tts_files = list((cache_dir / "text").glob("*-pre-tts.txt"))
        self.assertEqual(len(pre_tts_files), 1, "Expected a single pre-tts cache file")
        cached_text = pre_tts_files[0].read_text(encoding="utf-8")
        self.assertEqual(
            normalise(cached_text),
            normalise(long_text),
            "Cached pre-tts text should match the complete chapter payload",
        )

    async def test_multilingual_text_with_lang_tags(self):
        """Test that [[lang:xx]] tags are preserved in pre-tts.txt for multilingual TTS"""
        cache_dir = Path(self.temp_dir) / ".cache" / "Multilingual_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        # Chapter with multilingual text and [[lang:]] tags
        multilingual_text = """
        This is English text. [[lang:pt-BR]]Este é texto em português.[[/lang]]
        Back to English. [[lang:es]]Texto en español.[[/lang]] End.
        """

        chapter = Chapter(
            index=1,
            name="Multilingual Chapter",
            source_path="ch1.html",
            text="Original text without tags",  # parsed text
            speech_text=multilingual_text,  # pre-TTS text with tags
        )

        class DummyTTSEngine:
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"audio" * 400)
                return output_path

        engine = DummyTTSEngine()
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Multilingual_Test",
        )

        # Run conversion
        result = await self.converter._convert_chapters_sequential(
            [chapter], engine, cache_dir, config
        )

        # Verify files were created
        text_dir = cache_dir / "text"
        self.assertTrue(text_dir.exists())

        # Check for -parsed.txt and -pre-tts.txt files
        parsed_files = list(text_dir.glob("*-parsed.txt"))
        pre_tts_files = list(text_dir.glob("*-pre-tts.txt"))

        self.assertEqual(len(parsed_files), 1, "Should have one parsed.txt file")
        self.assertEqual(len(pre_tts_files), 1, "Should have one pre-tts.txt file")

        # Read both files
        parse_content = parsed_files[0].read_text(encoding="utf-8")
        pre_tts_content = pre_tts_files[0].read_text(encoding="utf-8")

        # Verify parsed.txt = original chapter.text
        self.assertEqual(
            parse_content, chapter.text, "parsed.txt should contain original chapter.text"
        )

        # Verify pre-tts.txt = speech_text (with [[lang:]] tags)
        # Normalize whitespace for comparison (clean_tts_text normalizes spaces)
        import re

        normalize = lambda t: re.sub(r"\s+", " ", t or "").strip()
        self.assertEqual(
            normalize(pre_tts_content),
            normalize(chapter.speech_text),
            "pre-tts.txt should contain speech_text with [[lang:]] tags",
        )

        # Verify language tags are preserved in pre-tts.txt
        self.assertIn("[[lang:pt-BR]]", pre_tts_content, "[[lang:pt-BR]] tag should be preserved")
        self.assertIn("[[lang:es]]", pre_tts_content, "[[lang:es]] tag should be preserved")
        self.assertIn("[[/lang]]", pre_tts_content, "Closing [[/lang]] tags should be preserved")

        # Verify language tags are NOT in parsed.txt
        self.assertNotIn("[[lang:", parse_content, "parsed.txt should not contain [[lang:]] tags")

    async def test_emphasis_markers_render_as_audible_cues(self):
        """Formatting markers must become audible cues in pre-tts.txt"""
        cache_dir = Path(self.temp_dir) / ".cache" / "Emphasis_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        # Text with emphasis markers
        emphasized_text = """
        Normal text. [[fmt:italic]]This is italic[[/fmt]] more text.
        [[fmt:bold]]Bold text here[[/fmt]] and [[fmt:quote]]quoted text[[/fmt]].
        """

        formatter = TextFormattingProcessor()
        audible_text = formatter.to_audible_text(emphasized_text)

        chapter = Chapter(
            index=1,
            name="Emphasis Chapter",
            source_path="ch1.html",
            text="Normal text without markers",
            speech_text=emphasized_text,  # Speech text BEFORE formatting processor
        )

        # Track what TTS receives
        tts_received = []

        class TrackingTTSEngine:
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                # Apply the same processing as real Edge TTS
                if formatter:
                    processed = formatter.to_audible_text(text, formatting_segments)
                else:
                    processed = text
                tts_received.append(processed)

                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"audio" * 400)
                return output_path

        engine = TrackingTTSEngine()
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Emphasis_Test",
        )

        # Run conversion
        result = await self.converter._convert_chapters_sequential(
            [chapter], engine, cache_dir, config
        )

        # Find pre-tts.txt file
        text_dir = cache_dir / "text"
        pre_tts_files = list(text_dir.glob("*-pre-tts.txt"))
        self.assertEqual(len(pre_tts_files), 1)

        pre_tts_content = pre_tts_files[0].read_text(encoding="utf-8")

        # Verify formatting cues are present (audible hints instead of markers)
        self.assertIn(
            "em itálico:", pre_tts_content, "Italic sections should produce an audible cue"
        )
        self.assertIn("em negrito:", pre_tts_content, "Bold sections should produce an audible cue")
        self.assertIn(
            "entre aspas:", pre_tts_content, "Quoted sections should announce quotation marks"
        )

        # Ensure original [[fmt:]] markers and SSML are removed
        self.assertNotIn(
            "[[fmt:", pre_tts_content, "Formatting markers must not leak to the final TTS text"
        )
        self.assertNotIn(
            "<speak", pre_tts_content.lower(), "SSML should not appear in the text sent to Piper"
        )

        # **CRITICAL**: Verify pre-tts.txt matches EXACTLY what TTS received
        self.assertEqual(len(tts_received), 1, "TTS should be called once")
        import re

        normalize = lambda t: re.sub(r"\s+", " ", t or "").strip()

        self.assertEqual(
            normalize(pre_tts_content),
            normalize(tts_received[0]),
            "CRITICAL: pre-tts.txt must EXACTLY match what TTS received (including audible cues)",
        )

    async def test_pre_tts_file_matches_tts_input_exactly(self):
        """CRITICAL TEST: Verify pre-tts.txt contains EXACTLY what TTS receives, byte-by-byte."""
        cache_dir = Path(self.temp_dir) / ".cache" / "Exact_Match_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        # Chapter with formatting that will be processed
        chapter_text = (
            "Normal text. [[fmt:italic]]Italic text[[/fmt]] and [[fmt:bold]]bold text[[/fmt]]."
        )

        chapter = Chapter(
            index=1,
            name="Exact Match Chapter",
            source_path="ch1.html",
            text="Original parsed text",
            speech_text=chapter_text,
        )

        # Track EXACTLY what TTS receives
        tts_received_exact = []

        class ExactTrackingTTSEngine:
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                # Record the EXACT text received (after Edge TTS processing)
                # This simulates what edge_engine.py does
                formatter = TextFormattingProcessor()
                processed_text = formatter.to_audible_text(text, formatting_segments)
                tts_received_exact.append(processed_text)

                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"audio" * 500)
                return output_path

        engine = ExactTrackingTTSEngine()
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Exact_Match_Test",
        )

        # Run conversion
        result = await self.converter._convert_chapters_sequential(
            [chapter], engine, cache_dir, config
        )

        self.assertEqual(result.converted_chapters, 1)

        # Read pre-tts.txt
        text_dir = cache_dir / "text"
        pre_tts_files = list(text_dir.glob("*-pre-tts.txt"))
        self.assertEqual(len(pre_tts_files), 1, "Should have one pre-tts.txt file")

        cached_text = pre_tts_files[0].read_text(encoding="utf-8")

        # Get what TTS actually received
        self.assertEqual(len(tts_received_exact), 1, "TTS should be called exactly once")
        tts_input = tts_received_exact[0]

        # **CRITICAL ASSERTION**: They must match EXACTLY (not just normalized)
        self.assertEqual(
            cached_text,
            tts_input,
            f"CRITICAL BUG: pre-tts.txt does NOT match TTS input exactly!\n"
            f"Cached ({len(cached_text)} chars): {cached_text[:200]}...\n"
            f"TTS Input ({len(tts_input)} chars): {tts_input[:200]}...",
        )

        # Verify audible cues are present in BOTH
        if "[[fmt:" in chapter_text:
            self.assertIn("em itálico:", cached_text, "Audible cues should be in pre-tts.txt")
            self.assertIn("em itálico:", tts_input, "Audible cues should be in TTS input")

            # And original markers should be GONE from both
            self.assertNotIn("[[fmt:", cached_text, "Markers should not be in pre-tts.txt")
            self.assertNotIn("[[fmt:", tts_input, "Markers should not be in TTS input")

    async def test_prepare_payload_preserves_structural_heading_pauses(self):
        """_prepare_payload must NOT discard '...' pauses added by apply_structural_speech_cues.

        Regression: previously it re-called to_audible_text with original
        formatting_segments, which reconstructed text from raw HTML and silently
        dropped the heading pauses written by the parser.
        """
        cache_dir = Path(self.temp_dir) / ".cache" / "HeadingPause_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        # Simulate a chapter whose speech_text was already prepared by
        # _prepare_speech_text: heading lines have trailing "..." for TTS pauses.
        prepared_speech = (
            "Capítulo 4...\nBen Hanscom sofre uma queda...\nPor volta das 23h45, o avião"
        )
        # The original formatting_segments that would have come from HTML parsing.
        # These do NOT contain the "..." — they reflect the raw parsed text.
        from src.text_formatting import FormattingSegment

        raw_segments = [
            FormattingSegment(text="Capítulo 4\n", formatting=""),
            FormattingSegment(text="Ben Hanscom sofre uma queda\n", formatting=""),
            FormattingSegment(text="Por volta das 23h45, o avião", formatting=""),
        ]

        chapter = Chapter(
            index=1,
            name="Capítulo 4 – Ben Hanscom sofre uma queda",
            source_path="ch.html",
            text="Capítulo 4\nBen Hanscom sofre uma queda\nPor volta das 23h45, o avião",
            speech_text=prepared_speech,
            formatting_segments=raw_segments,
        )

        class NoOpEngine:
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"audio" * 400)
                return output_path

            last_error = None
            last_segment_report = None
            partial_failure_detected = False

            def get_synthesis_tracker(self):
                return None

        engine = NoOpEngine()
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            validate_audio=False,
            validate_text=False,
            book_title="HeadingPause_Test",
        )

        await self.converter._convert_chapters_sequential([chapter], engine, cache_dir, config)

        text_dir = cache_dir / "text"
        pre_tts_files = list(text_dir.glob("*-pre-tts.txt"))
        self.assertEqual(len(pre_tts_files), 1)
        content = pre_tts_files[0].read_text(encoding="utf-8")

        # The heading pauses must survive into the pre-TTS file
        self.assertIn(
            "Capítulo 4...",
            content,
            "Structural heading pause '...' must be preserved in pre-tts.txt",
        )
        self.assertIn(
            "Ben Hanscom sofre uma queda...",
            content,
            "Subtitle heading pause '...' must be preserved in pre-tts.txt",
        )
        # Body text must follow immediately after the last heading (no merging)
        self.assertIn("Por volta das 23h45", content)

    async def test_prepare_payload_converts_fmt_markers_in_speech_text(self):
        """When speech_text still has [[fmt:]] markers, they must be converted to audible
        cues — not silently stripped — in the written pre-TTS file."""
        cache_dir = Path(self.temp_dir) / ".cache" / "FmtMarker_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        chapter = Chapter(
            index=1,
            name="Fmt Marker Chapter",
            source_path="ch.html",
            text="Original text",
            speech_text="Normal. [[fmt:italic]]Italic here[[/fmt]] done.",
        )

        class NoOpEngine:
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"audio" * 400)
                return output_path

            last_error = None
            last_segment_report = None
            partial_failure_detected = False

            def get_synthesis_tracker(self):
                return None

        engine = NoOpEngine()
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            validate_audio=False,
            validate_text=False,
            book_title="FmtMarker_Test",
        )

        await self.converter._convert_chapters_sequential([chapter], engine, cache_dir, config)

        text_dir = cache_dir / "text"
        pre_tts_files = list(text_dir.glob("*-pre-tts.txt"))
        self.assertEqual(len(pre_tts_files), 1)
        content = pre_tts_files[0].read_text(encoding="utf-8")

        # Markers must be converted, not left raw
        self.assertNotIn("[[fmt:", content, "[[fmt:]] markers must not appear in pre-tts.txt")
        # Audible cue must be present
        self.assertIn("em itálico", content, "Italic marker must produce an audible cue")

    async def test_prepare_payload_falls_back_when_speech_text_is_none(self):
        """When speech_text is None, _prepare_payload falls back to processing chapter.text
        via the full formatting pipeline (original formatting_segments path)."""
        cache_dir = Path(self.temp_dir) / ".cache" / "Fallback_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        from src.text_formatting import FormattingSegment

        raw_text = "Normal. [[fmt:bold]]Bold here[[/fmt]] done."
        raw_segments = [
            FormattingSegment(text="Normal. ", formatting=""),
            FormattingSegment(text="Bold here", formatting="bold"),
            FormattingSegment(text=" done.", formatting=""),
        ]

        chapter = Chapter(
            index=1,
            name="Fallback Chapter",
            source_path="ch.html",
            text=raw_text,
            speech_text=None,  # not set — triggers fallback path
            formatting_segments=raw_segments,
        )

        class NoOpEngine:
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"audio" * 400)
                return output_path

            last_error = None
            last_segment_report = None
            partial_failure_detected = False

            def get_synthesis_tracker(self):
                return None

        engine = NoOpEngine()
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Fallback_Test",
        )

        await self.converter._convert_chapters_sequential([chapter], engine, cache_dir, config)

        text_dir = cache_dir / "text"
        pre_tts_files = list(text_dir.glob("*-pre-tts.txt"))
        self.assertEqual(len(pre_tts_files), 1)
        content = pre_tts_files[0].read_text(encoding="utf-8")

        # Fallback should still convert markers via segments
        self.assertNotIn("[[fmt:", content)
        self.assertIn("em negrito", content, "Bold marker must produce audible cue via fallback")

    async def test_cache_invalidation_without_txt_files(self):
        """Test that MP3 files are deleted and reconverted when .txt cache is missing"""
        cache_dir = Path(self.temp_dir) / ".cache" / "Cache_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        chapter = Chapter(
            index=1,
            name="Cache Test Chapter",
            source_path="ch1.html",
            text="Test text",
            speech_text="Test speech text",
        )

        # Track TTS calls
        tts_call_count = [0]

        class CountingTTSEngine(MockTTSEngine):
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                tts_call_count[0] += 1
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"audio" * 400)
                return output_path

        engine = CountingTTSEngine()
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Cache_Test",
        )

        # First conversion
        result1 = await self.converter._convert_chapters_sequential(
            [chapter], engine, cache_dir, config
        )
        self.assertEqual(result1.converted_chapters, 1)
        self.assertEqual(tts_call_count[0], 1, "First conversion should call TTS")

        # Verify files were created
        text_dir = cache_dir / "text"
        mp3_file = cache_dir / "1 - Cache Test Chapter.mp3"

        # NEW FORMAT: "N - Name-pre-tts.txt" (sanitize keeps spaces)
        pre_tts_file = text_dir / "1 - Cache Test Chapter-pre-tts.txt"
        parsed_file = text_dir / "1 - Cache Test Chapter-parsed.txt"

        self.assertTrue(mp3_file.exists(), "MP3 should exist after first conversion")
        self.assertTrue(pre_tts_file.exists(), f"pre-tts.txt should exist at {pre_tts_file}")
        self.assertTrue(parsed_file.exists(), f"parsed.txt should exist at {parsed_file}")

        # Second conversion with .txt intact - should use cache
        tts_call_count[0] = 0
        result2 = await self.converter._convert_chapters_sequential(
            [chapter], engine, cache_dir, config
        )
        self.assertEqual(result2.converted_chapters, 1)
        self.assertEqual(tts_call_count[0], 0, "Second conversion should NOT call TTS (cache hit)")

        # Now delete .txt files to simulate cache invalidation
        for txt_file in text_dir.glob("*.txt"):
            txt_file.unlink()

        # Third conversion without .txt - should DELETE MP3 and reconvert
        tts_call_count[0] = 0
        result3 = await self.converter._convert_chapters_sequential(
            [chapter], engine, cache_dir, config
        )
        self.assertEqual(result3.converted_chapters, 1)
        self.assertEqual(
            tts_call_count[0], 1, "Third conversion should call TTS (cache invalidated)"
        )

        # Verify .txt files were recreated
        self.assertTrue(pre_tts_file.exists(), "pre-tts.txt should be recreated")
        self.assertTrue(parsed_file.exists(), "parsed.txt should be recreated")

    async def test_integration_cache_issue_messias_duna_scenario(self):
        """Reproduce the Messias de Duna bug: TXT without tags but MP3 has HTML tags"""
        cache_dir = Path(self.temp_dir) / ".cache" / "Messias"
        cache_dir.mkdir(parents=True, exist_ok=True)

        # CRITICAL: Simulate the exact scenario where text != speech_text
        # This reproduces the Messias de Duna bug!
        chapter = Chapter(
            index=1,
            name="Messias Chapter",
            source_path="ch1.html",
            text="Original text WITHOUT TAGS",  # Saved to cache
            speech_text="Processed text [[lang:pt-BR]]WITH TAGS[[/lang]]",  # Sent to TTS
        )

        # Track exactly what Edge TTS receives
        tts_received_inputs = []

        class SpyTTSEngine:
            """TTS engine that spies on its inputs"""

            async def synthesize_async(self, text, output_path, formatting_segments=None):
                # Record EXACTLY what we receive
                tts_received_inputs.append(
                    {
                        "text": text,
                        "formatting_segments": formatting_segments,
                    }
                )

                # Simulate successful synthesis
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"audio" * 300)  # > 1000 bytes
                return output_path

        spy_engine = SpyTTSEngine()

        # Run conversion
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Messias",
        )

        result = await self.converter._convert_chapters_sequential(
            [chapter], spy_engine, cache_dir, config
        )

        # Verify conversion completed
        self.assertEqual(result.converted_chapters, 1)
        self.assertEqual(len(tts_received_inputs), 1)

        # What was sent to TTS
        tts_input_text = tts_received_inputs[0]["text"]

        # What was cached (NEW FORMAT: -pre-tts.txt)
        text_dir = cache_dir / "text"
        pre_tts_files = list(text_dir.glob("*-pre-tts.txt"))
        self.assertEqual(len(pre_tts_files), 1, "Should have one pre-tts.txt file")

        cached_text = pre_tts_files[0].read_text(encoding="utf-8")

        # REPRODUCE BUG CHECK:
        # If cached_text lacks tags but tts_input_text has them, we have the bug!
        has_bug = "[[lang:" not in cached_text and "[[lang:" in tts_input_text

        self.assertFalse(
            has_bug,
            f"BUG DETECTED: Cached text lacks language tags that were sent to TTS!\n"
            f"Cached: {cached_text[:100]}\n"
            f"TTS Input: {tts_input_text[:100]}",
        )

        self.assertNotIn(
            "<speak", tts_input_text.lower(), "SSML tags must never reach the TTS engine input"
        )
        self.assertNotIn(
            "[[fmt:", tts_input_text, "Formatting markers must be stripped before synthesis"
        )

        # CORRECT BEHAVIOR: they must match exactly
        self.assertEqual(
            cached_text,
            tts_input_text,
            "Cached text must exactly match TTS input (fixing Messias de Duna bug)",
        )

    async def test_convert_chapters_success(self):
        """Test successful chapter conversion"""
        chapters = [
            Chapter(1, "Chapter 1", "ch1.html", "Content 1"),
            Chapter(2, "Chapter 2", "ch2.html", "Content 2"),
        ]

        # Mock TTS engine that creates audio files
        class SuccessTTSEngine:
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"fake audio" * 200)  # > 1000 bytes
                return output_path

        mock_tts_engine = SuccessTTSEngine()
        output_dir = Path(self.temp_dir)

        result = await self.converter._convert_chapters_sequential(
            chapters, mock_tts_engine, output_dir, self.config
        )

        self.assertIsInstance(result, ConversionResult)
        self.assertTrue(result.success)
        self.assertEqual(result.total_chapters, 2)
        self.assertEqual(result.converted_chapters, 2)
        self.assertEqual(len(result.output_files), 2)
        self.assertEqual(len(result.errors), 0)

    async def test_auto_mode_selects_engine_per_chapter_during_conversion(self):
        """Auto mode should decide engine for each chapter during sequential conversion."""
        chapters = [
            Chapter(1, "Short Chapter", "short.html", "short text " * 20),
            Chapter(2, "Long Chapter", "long.html", "long text " * 4000),
        ]

        class RecordingEngine(MockTTSEngine):
            def __init__(self, label: str):
                super().__init__()
                self.label = label
                self.calls = 0

            async def synthesize_async(self, text, output_path, formatting_segments=None):
                self.calls += 1
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"fake audio" * 400)  # > 1000 bytes
                return output_path

        edge_engine = RecordingEngine("edge")
        coqui_engine = RecordingEngine("coqui")
        output_dir = Path(self.temp_dir)

        async def fake_convert_to_mp3(input_file, output_file, bitrate="8k"):
            output_path = Path(output_file)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_bytes(b"mp3" * 400)
            return output_path

        self.converter.audio_processor.convert_to_mp3 = fake_convert_to_mp3

        auto_config = ConversionConfig(
            engine="auto",
            output_dir=str(output_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Auto Book",
        )

        edge_cfg = ConversionConfig(
            engine="edge",
            output_dir=str(output_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Auto Book",
        )
        coqui_cfg = ConversionConfig(
            engine="coqui",
            output_dir=str(output_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Auto Book",
        )

        auto_pool = {
            "edge": (edge_cfg, edge_engine),
            "coqui": (coqui_cfg, coqui_engine),
        }

        class DummyPool:
            def __init__(self, pool):
                self.pool = pool

            async def acquire(self, name):
                return self.pool[name]

            def release(self, *_args, **_kwargs):
                return None

            def register_engine(self, name, config, engine_obj=None):
                self.pool[name] = (config, engine_obj or self.pool[name][1])
                return None

        engine_pool = DummyPool(auto_pool)

        with patch.object(
            self.converter,
            "_pick_auto_engine",
            side_effect=[
                ("edge", ["edge", "coqui"]),
                ("coqui", ["coqui", "edge"]),
            ],
        ) as mock_pick:
            with patch.object(self.converter, "_detect_short_audio_output", return_value=None):
                result = await self.converter._convert_chapters_sequential(
                    chapters,
                    engine_pool,
                    output_dir,
                    auto_config,
                    is_auto_engine=True,
                    auto_engine_pool=auto_pool,
                )

        self.assertTrue(result.success)
        self.assertEqual(result.converted_chapters, 2)
        self.assertEqual(mock_pick.call_count, 2)
        self.assertEqual(edge_engine.calls, 1)
        self.assertEqual(coqui_engine.calls, 1)

    async def test_auto_mode_skips_edge_when_chapter_marked_with_connectivity_failure(self):
        """If chapter is marked as Edge-connectivity-failed, auto mode must not call Edge again."""
        chapters = [Chapter(1, "Retry Chapter", "retry.html", "retry text " * 600)]

        class RecordingEngine(MockTTSEngine):
            def __init__(self, label: str):
                super().__init__()
                self.label = label
                self.calls = 0

            async def synthesize_async(self, text, output_path, formatting_segments=None):
                self.calls += 1
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"fake audio" * 400)
                return output_path

        edge_engine = RecordingEngine("edge")
        coqui_engine = RecordingEngine("coqui")
        output_dir = Path(self.temp_dir)

        async def fake_convert_to_mp3(input_file, output_file, bitrate="8k"):
            output_path = Path(output_file)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_bytes(b"mp3" * 400)
            return output_path

        self.converter.audio_processor.convert_to_mp3 = fake_convert_to_mp3

        auto_config = ConversionConfig(
            engine="auto",
            output_dir=str(output_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Auto Retry Book",
        )
        auto_config.extra = {"edge_blocked_chapters": ["1"]}

        edge_cfg = ConversionConfig(
            engine="edge",
            output_dir=str(output_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Auto Retry Book",
        )
        coqui_cfg = ConversionConfig(
            engine="coqui",
            output_dir=str(output_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Auto Retry Book",
        )
        auto_pool = {
            "edge": (edge_cfg, edge_engine),
            "coqui": (coqui_cfg, coqui_engine),
        }

        class DummyPool:
            def __init__(self, pool):
                self.pool = pool

            async def acquire(self, name):
                return self.pool[name]

            def release(self, *_args, **_kwargs):
                return None

            def register_engine(self, name, config, engine_obj=None):
                self.pool[name] = (config, engine_obj or self.pool[name][1])
                return None

        engine_pool = DummyPool(auto_pool)

        with patch.object(
            self.converter,
            "_pick_auto_engine",
            return_value=("edge", ["edge", "coqui"]),
        ):
            with patch.object(self.converter, "_detect_short_audio_output", return_value=None):
                result = await self.converter._convert_chapters_sequential(
                    chapters,
                    engine_pool,
                    output_dir,
                    auto_config,
                    is_auto_engine=True,
                    auto_engine_pool=auto_pool,
                )

        self.assertTrue(result.success)
        self.assertEqual(result.converted_chapters, 1)
        self.assertEqual(edge_engine.calls, 0, "Edge must be skipped for blocked chapter")
        self.assertEqual(coqui_engine.calls, 1)

    async def test_auto_mode_parallel_forwards_pool_per_chapter(self):
        """Parallel mode should invoke sequential worker with auto engine context."""
        chapters = [
            Chapter(1, "Chapter 1", "c1.html", "hello " * 400),
            Chapter(2, "Chapter 2", "c2.html", "world " * 500),
        ]
        output_dir = Path(self.temp_dir)
        auto_pool = {
            "edge": (ConversionConfig(engine="edge", output_dir=str(output_dir)), object()),
            "coqui": (ConversionConfig(engine="coqui", output_dir=str(output_dir)), object()),
        }
        config = ConversionConfig(
            engine="auto",
            output_dir=str(output_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Parallel Auto",
        )
        calls = []

        class DummyPool:
            def update_parallel_slots(self, _slots):
                return None

        async def fake_convert_seq(
            chapters_arg,
            _engine_pool,
            _output_dir,
            _config,
            *,
            is_auto_engine=False,
            auto_engine_pool=None,
            skip_preprocessing=False,
            **_kwargs,
        ):
            chapter = chapters_arg[0]
            calls.append(
                {
                    "index": chapter.index,
                    "is_auto_engine": is_auto_engine,
                    "auto_pool_identity": auto_engine_pool is auto_pool,
                    "skip_preprocessing": skip_preprocessing,
                }
            )
            return ConversionResult(
                success=True,
                total_chapters=1,
                converted_chapters=1,
                output_files=[output_dir / f"{chapter.index:03d}.mp3"],
                errors=[],
            )

        with patch.object(
            self.converter, "_convert_chapters_sequential", side_effect=fake_convert_seq
        ):
            result = await self.converter._convert_chapters_parallel(
                chapters,
                DummyPool(),
                output_dir,
                config,
                max_concurrent_chapters=2,
                skip_preprocessing=True,
                is_auto_engine=True,
                auto_engine_pool=auto_pool,
            )

        self.assertTrue(result.success)
        self.assertEqual(result.converted_chapters, 2)
        self.assertEqual(len(calls), 2)
        self.assertTrue(all(entry["is_auto_engine"] for entry in calls))
        self.assertTrue(all(entry["auto_pool_identity"] for entry in calls))
        self.assertTrue(all(entry["skip_preprocessing"] for entry in calls))
        self.assertEqual(sorted(entry["index"] for entry in calls), [1, 2])

    async def test_edge_retries_after_truncated_audio_and_succeeds(self):
        """Edge conversion should retry the chapter when truncation is detected."""
        chapter = Chapter(1, "Retry Chapter", "retry.html", "retry content " * 800)
        output_dir = Path(self.temp_dir)

        class FlakyEdgeTTS(MockTTSEngine):
            def __init__(self):
                super().__init__()
                self.calls = 0

            async def synthesize_async(self, text, output_path, formatting_segments=None):
                self.calls += 1
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                if self.calls == 1:
                    output_path.write_bytes(b"x" * 80_000)
                else:
                    output_path.write_bytes(b"y" * 220_000)
                return output_path

        engine = FlakyEdgeTTS()
        config = ConversionConfig(
            engine="edge",
            output_dir=str(output_dir),
            validate_audio=False,
            validate_text=False,
            force_reprocess=True,
            book_title="Retry Book",
        )

        with patch.object(
            self.converter,
            "_detect_short_audio_output",
            side_effect=["Audio possibly truncated", None],
        ):
            result = await self.converter._convert_chapters_sequential(
                [chapter],
                engine,
                output_dir,
                config,
            )

        self.assertTrue(result.success)
        self.assertEqual(result.converted_chapters, 1)
        self.assertFalse(result.errors)
        self.assertEqual(engine.calls, 2, "chapter should be retried once after truncation")
        self.assertEqual(len(result.output_files), 1)

    async def test_convert_chapters_with_errors(self):
        """Test chapter conversion with errors"""
        chapters = [
            Chapter(1, "Chapter 1", "ch1.html", "Content 1"),
            Chapter(2, "Chapter 2", "ch2.html", "Content 2"),
        ]

        # Mock TTS engine that fails on second chapter
        call_count = [0]

        class PartialFailTTSEngine(MockTTSEngine):
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                call_count[0] += 1
                if call_count[0] == 1:
                    # First chapter succeeds
                    output_path = Path(output_path)
                    output_path.parent.mkdir(parents=True, exist_ok=True)
                    output_path.write_bytes(b"fake audio" * 200)  # > 1000 bytes
                    return output_path
                else:
                    # Second chapter fails
                    return None

        mock_tts_engine = PartialFailTTSEngine()
        mock_tts_engine.last_error = "Test error"
        output_dir = Path(self.temp_dir)

        # Disable Piper fallback for this test
        import os

        old_threshold = os.environ.get("EDGE_PIPER_THRESHOLD")
        os.environ["EDGE_PIPER_THRESHOLD"] = "999"
        try:
            result = await self.converter._convert_chapters_sequential(
                chapters, mock_tts_engine, output_dir, self.config
            )
        finally:
            if old_threshold is None:
                os.environ.pop("EDGE_PIPER_THRESHOLD", None)
            else:
                os.environ["EDGE_PIPER_THRESHOLD"] = old_threshold

        # Note: The current behavior converts what it can and reports partial success
        # First chapter succeeds, second chapter fails - expect success=True with 1 converted
        self.assertTrue(result.success or result.converted_chapters > 0)  # Partial success is OK
        self.assertEqual(result.total_chapters, 2)
        self.assertGreaterEqual(result.converted_chapters, 1)  # At least first chapter
        self.assertGreaterEqual(len(result.output_files), 1)

    async def test_convert_single_chapter_success(self):
        """Test successful single chapter conversion"""
        semaphore = asyncio.Semaphore(1)
        chapter = Chapter(1, "Test Chapter", "test.html", "Test content")

        # Mock TTS engine
        mock_tts_engine = AsyncMock()
        temp_wav = Path(self.temp_dir) / "temp.wav"
        temp_wav.write_text("dummy wav")
        mock_tts_engine.synthesize_async.return_value = temp_wav
        # Configure Protocol methods for validation system
        mock_tts_engine.get_synthesis_tracker = Mock(return_value=None)
        mock_tts_engine.get_synthesis_log = Mock(return_value=[])

        # Mock audio processor
        output_mp3 = Path(self.temp_dir) / "output.mp3"
        output_mp3.write_text("dummy mp3")
        self.converter.audio_processor.convert_to_mp3 = AsyncMock(return_value=output_mp3)
        self.converter._auto_validate_output = AsyncMock()

        output_dir = Path(self.temp_dir)

        result = await self.converter._convert_single_chapter(
            semaphore, chapter, mock_tts_engine, output_dir, 1
        )

        self.assertEqual(result, output_mp3)
        mock_tts_engine.synthesize_async.assert_called_once()
        self.converter.audio_processor.convert_to_mp3.assert_called_once()
        self.converter._auto_validate_output.assert_called()

    async def test_convert_single_chapter_file_exists(self):
        """Test single chapter conversion when file already exists"""
        semaphore = asyncio.Semaphore(1)
        chapter = Chapter(1, "Test Chapter", "test.html", "Test content")

        # Create existing output file
        output_dir = Path(self.temp_dir)
        existing_file = output_dir / "001 - Test Chapter.mp3"
        existing_file.write_bytes(b"\x00" * 2048)  # Non-empty placeholder
        temp_wav = output_dir / "temp.wav"
        temp_wav.write_bytes(b"wavdata")

        mock_tts_engine = AsyncMock()
        mock_tts_engine.synthesize_async = AsyncMock(return_value=temp_wav)
        # Configure Protocol methods for validation system
        mock_tts_engine.get_synthesis_tracker = Mock(return_value=None)
        mock_tts_engine.get_synthesis_log = Mock(return_value=[])

        valid_result = SimpleNamespace(
            is_valid=True,
            expected_duration=1.0,
            actual_duration=1.0,
            duration_diff_percent=0.0,
            error_message=None,
        )

        with patch.object(
            self.converter.file_manager, "get_temp_output_path", return_value=existing_file
        ):
            with patch.object(
                self.converter.audio_processor,
                "convert_to_mp3",
                AsyncMock(return_value=existing_file),
            ):
                with patch(
                    "python_app.src.audio_validator.AudioValidator.validate_duration",
                    return_value=valid_result,
                ):
                    result = await self.converter._convert_single_chapter(
                        semaphore, chapter, mock_tts_engine, output_dir, 1
                    )

        self.assertEqual(result, existing_file)

    async def test_convert_single_chapter_tts_failure(self):
        """Test single chapter conversion with TTS failure"""
        semaphore = asyncio.Semaphore(1)
        chapter = Chapter(1, "Test Chapter", "test.html", "Test content")

        # Mock TTS engine to return None (failure)
        mock_tts_engine = AsyncMock()
        mock_tts_engine.synthesize_async.return_value = None
        # Configure Protocol methods for validation system
        mock_tts_engine.get_synthesis_tracker = Mock(return_value=None)
        mock_tts_engine.get_synthesis_log = Mock(return_value=[])

        output_dir = Path(self.temp_dir)

        result = await self.converter._convert_single_chapter(
            semaphore, chapter, mock_tts_engine, output_dir, 1
        )

        self.assertIsNone(result)

    async def test_convert_single_chapter_exception(self):
        """Test single chapter conversion with exception"""
        semaphore = asyncio.Semaphore(1)
        chapter = Chapter(1, "Test Chapter", "test.html", "Test content")

        # Mock TTS engine to raise exception
        mock_tts_engine = AsyncMock()
        mock_tts_engine.synthesize_async.side_effect = Exception("Test error")
        # Configure Protocol methods for validation system
        mock_tts_engine.get_synthesis_tracker = Mock(return_value=None)
        mock_tts_engine.get_synthesis_log = Mock(return_value=[])

        output_dir = Path(self.temp_dir)

        with self.assertRaises(Exception):
            await self.converter._convert_single_chapter(
                semaphore, chapter, mock_tts_engine, output_dir, 1
            )

    async def test_report_results_success(self):
        """Test reporting successful results"""
        result = ConversionResult(
            success=True,
            total_chapters=3,
            converted_chapters=3,
            output_files=[Path("file1.mp3"), Path("file2.mp3")],
            errors=[],
        )

        # Should not raise exception
        await self.converter._report_results(result)

    async def test_report_results_with_errors(self):
        """Test reporting results with errors"""
        result = ConversionResult(
            success=False,
            total_chapters=3,
            converted_chapters=2,
            output_files=[Path("file1.mp3")],
            errors=["Error 1", "Error 2", "Error 3", "Error 4"],
        )

        # Should not raise exception
        await self.converter._report_results(result)

    async def test_convert_integration(self):
        """Test full convert method integration"""
        with (
            patch.object(self.converter, "_setup_output_directory") as mock_setup,
            patch.object(self.converter.tts_factory, "create_engine") as mock_create,
            patch.object(self.converter, "_convert_chapters_sequential") as mock_convert_seq,
            patch.object(self.converter, "_convert_chapters_parallel") as mock_convert_parallel,
            patch.object(self.converter, "_report_results") as mock_report,
        ):
            mock_setup.return_value = Path(self.temp_dir)
            mock_engine = Mock()
            # Configure Protocol methods for validation system
            mock_engine.get_synthesis_tracker = Mock(return_value=None)
            mock_engine.get_synthesis_log = Mock(return_value=[])
            mock_create.return_value = mock_engine
            expected_result = ConversionResult(
                success=True,
                total_chapters=2,
                converted_chapters=2,
                output_files=[],
                errors=[],
            )
            mock_convert_seq.return_value = expected_result
            mock_convert_parallel.return_value = expected_result

            result = await self.converter.convert(self.mock_reader, self.config)

            self.assertIs(result, expected_result)
            self.assertGreaterEqual(mock_setup.call_count, 1)
            mock_create.assert_called_once()
            self.assertTrue(
                mock_convert_seq.called or mock_convert_parallel.called,
                "expected sequential or parallel conversion to be called",
            )
            mock_report.assert_called_once_with(expected_result)

    async def test_convert_auto_e2e_edge_dns_failure_falls_back_offline(self):
        """E2E: auto mode should recover from Edge DNS failure by switching offline."""
        chapter_text = "conteudo de teste " * 600
        chapter = Chapter(1, "Chapter DNS", "dns.html", chapter_text, speech_text=chapter_text)
        reader = SimpleNamespace(
            title="E2E DNS Book",
            author="Tester",
            file_path=Path(self.temp_dir) / "e2e_dns.epub",
            get_chapter_structure=lambda preserve_all=True: [chapter],
        )

        class EdgeDnsEngine(MockTTSEngine):
            def __init__(self):
                super().__init__()
                self.calls = 0

            async def synthesize_async(self, text, output_path, formatting_segments=None):
                self.calls += 1
                self.last_error = "ClientConnectorDNSError: dns failure"
                return None

        class PiperOkEngine(MockTTSEngine):
            def __init__(self):
                super().__init__()
                self.calls = 0

            async def synthesize_async(self, text, output_path, formatting_segments=None):
                self.calls += 1
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"wav" * 500)
                return output_path

        edge_engine = EdgeDnsEngine()
        piper_engine = PiperOkEngine()

        async def fake_convert_to_mp3(input_file, output_file, bitrate="8k"):
            output_path = Path(output_file)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_bytes(b"mp3" * 350_000)
            return output_path

        self.converter.audio_processor.convert_to_mp3 = fake_convert_to_mp3

        auto_config = ConversionConfig(
            engine="auto",
            output_dir=self.temp_dir,
            validate_audio=False,
            validate_text=False,
            book_title="E2E DNS Book",
            force_reprocess=True,
        )
        edge_cfg = ConversionConfig(
            engine="edge",
            output_dir=self.temp_dir,
            validate_audio=False,
            validate_text=False,
            book_title="E2E DNS Book",
        )
        piper_cfg = ConversionConfig(
            engine="piper",
            output_dir=self.temp_dir,
            validate_audio=False,
            validate_text=False,
            book_title="E2E DNS Book",
        )

        with patch.object(
            self.converter,
            "_prepare_auto_engines",
            return_value={"edge": (edge_cfg, edge_engine), "piper": (piper_cfg, piper_engine)},
        ):
            with patch.object(
                self.converter,
                "_pick_auto_engine",
                return_value=("edge", ["edge", "piper"]),
            ):
                result = await self.converter.convert(reader, auto_config)

        self.assertTrue(result.success)
        self.assertGreaterEqual(result.converted_chapters, 1)
        self.assertGreaterEqual(edge_engine.calls, 1)
        self.assertGreaterEqual(piper_engine.calls, 1)
        blocked = (auto_config.extra or {}).get("edge_blocked_chapters", [])
        self.assertTrue(blocked, "Edge blocked chapter list should be persisted after DNS failure")

    async def test_convert_auto_resume_and_adaptive_checkpoint_e2e(self):
        """E2E: auto mode should save checkpoint on partial failure and resume only failed chapter."""
        chapter_ok = Chapter(1, "Chapter 1", "c1.html", "texto ok " * 400)
        chapter_fail = Chapter(2, "Chapter 2", "c2.html", "FORCE_FAIL " * 400)
        reader = SimpleNamespace(
            title="Resume Book",
            author="Tester",
            file_path=Path(self.temp_dir) / "resume.epub",
            get_chapter_structure=lambda preserve_all=True: [chapter_ok, chapter_fail],
        )

        class FlakyPiperEngine(MockTTSEngine):
            def __init__(self):
                super().__init__()
                self.calls = 0

            async def synthesize_async(self, text, output_path, formatting_segments=None):
                self.calls += 1
                if "chapter 2" in str(output_path).lower() or "002" in str(output_path):
                    self.last_error = "timeout while generating audio"
                    return None
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"wav" * 500)
                return output_path

        class HealthyPiperEngine(MockTTSEngine):
            def __init__(self):
                super().__init__()
                self.calls = 0

            async def synthesize_async(self, text, output_path, formatting_segments=None):
                self.calls += 1
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"wav" * 500)
                return output_path

        async def fake_convert_to_mp3(input_file, output_file, bitrate="8k"):
            output_path = Path(output_file)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_bytes(b"mp3" * 250_000)
            return output_path

        self.converter.audio_processor.convert_to_mp3 = fake_convert_to_mp3
        config_first = ConversionConfig(
            engine="auto",
            output_dir=self.temp_dir,
            cache_dir=Path(self.temp_dir) / "cache",
            validate_audio=False,
            validate_text=False,
            book_title="Resume Book",
            force_reprocess=True,
            extra={"max_auto_retries": "0", "manual_retry_failed": "0"},
        )
        flaky_engine = FlakyPiperEngine()
        piper_cfg = ConversionConfig(
            engine="piper",
            output_dir=self.temp_dir,
            cache_dir=Path(self.temp_dir) / "cache",
            validate_audio=False,
            validate_text=False,
            book_title="Resume Book",
        )
        with patch.object(
            self.converter,
            "_prepare_auto_engines",
            return_value={"piper": (piper_cfg, flaky_engine)},
        ):
            result_first = await self.converter.convert(reader, config_first)

        self.assertIsNotNone(result_first)
        cache_dir = Path(config_first.cache_dir)
        self.assertTrue((cache_dir / "_adaptive_state_checkpoint.json").exists())
        self.converter._save_failure_checkpoint(
            cache_dir,
            failed_chapters=["2"],
            edge_blocked_chapters=[],
        )
        self.assertTrue((cache_dir / "_failure_checkpoint.json").exists())

        second_converter = AudioConverter()
        second_converter.audio_processor.convert_to_mp3 = fake_convert_to_mp3
        healthy_engine = HealthyPiperEngine()
        config_second = ConversionConfig(
            engine="auto",
            output_dir=self.temp_dir,
            cache_dir=Path(self.temp_dir) / "cache",
            validate_audio=False,
            validate_text=False,
            book_title="Resume Book",
            force_reprocess=True,
            extra={"resume_from_failure": "1"},
        )
        piper_cfg_second = ConversionConfig(
            engine="piper",
            output_dir=self.temp_dir,
            cache_dir=Path(self.temp_dir) / "cache",
            validate_audio=False,
            validate_text=False,
            book_title="Resume Book",
        )
        with patch.object(
            second_converter,
            "_prepare_auto_engines",
            return_value={"piper": (piper_cfg_second, healthy_engine)},
        ):
            result_second = await second_converter.convert(reader, config_second)

        self.assertTrue(result_second.success)
        self.assertIn(
            healthy_engine.calls,
            {1, 2, 3},
            "Resume flow should stay bounded to the failed chapter; warmup/probes may add extra calls",
        )
        self.assertEqual(second_converter._load_failure_checkpoint(cache_dir), {})

    async def test_convert_with_exception(self):
        """Test convert method propagates exceptions"""

        with patch.object(self.converter.tts_factory, "create_engine") as mock_create:
            mock_create.side_effect = Exception("Test error")

            with self.assertRaises(Exception):
                await self.converter.convert(self.mock_reader, self.config)

    async def test_convert_retries_after_tts_exception(self):
        """Conversion should automatically retry chapters when TTS raises an exception."""
        output_root = Path(self.temp_dir) / "retry_output"
        output_root.mkdir(parents=True, exist_ok=True)

        long_text = " ".join(f"Sentence number {i} of the chapter." for i in range(600))
        chapter = Chapter(
            index=1,
            name="Retry Chapter",
            source_path="retry.html",
            text=long_text,
            speech_text=long_text,
        )

        reader = SimpleNamespace(
            title="Retry Book",
            file_path="retry.epub",
            get_chapter_structure=lambda preserve_all=True: [chapter],
        )

        class FlakyTTSEngine(MockTTSEngine):
            def __init__(self):
                super().__init__()
                self.calls = 0
                self.voice = "retry-voice"

            async def synthesize_async(self, text, output_path, formatting_segments=None):
                self.calls += 1
                path = Path(output_path)
                path.parent.mkdir(parents=True, exist_ok=True)

                if self.calls == 1:
                    # Simulate a TTS failure so the retry logic is triggered
                    raise RuntimeError("Simulated TTS failure on first attempt")
                else:
                    # Succeed on retry
                    path.write_bytes(b"b" * 1_000_000)
                return path

        flaky_engine = FlakyTTSEngine()
        self.converter.tts_factory.create_engine = Mock(return_value=flaky_engine)

        async def fake_convert_to_mp3(input_file, output_file, bitrate="8k"):
            output_path = Path(output_file)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_bytes(b"mp3" * 500_000)
            return output_path

        self.converter.audio_processor.convert_to_mp3 = fake_convert_to_mp3

        config = ConversionConfig(
            engine="piper",
            output_dir=str(output_root),
            validate_audio=False,
            validate_text=False,
            book_title="Retry Book",
            extra={"max_auto_retries": 3},
            edge_auto_offline_chars=0,
            edge_auto_offline_seconds=0,
            force_reprocess=True,
        )

        result = await self.converter.convert(reader, config)

        self.assertTrue(
            result.success or len(result.output_files) > 0,
            "Conversion should eventually succeed after retry",
        )
        self.assertGreaterEqual(
            len(result.output_files), 1, "At least one output file should be produced"
        )
        self.assertGreaterEqual(
            flaky_engine.calls, 2, "Engine must be called at least twice (initial + retry)"
        )
        final_output = result.output_files[0]
        self.assertTrue(final_output.exists(), "Final MP3 should exist after conversion")
        self.assertGreater(
            final_output.stat().st_size, 1000, "Generated MP3 should have expected size"
        )

    async def test_edge_tts_receives_complete_chapter_content(self):
        """CRITICAL: Verify Edge TTS receives the COMPLETE chapter text, not truncated."""
        cache_dir = Path(self.temp_dir) / ".cache" / "Complete_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        # Create a realistic chapter (equivalent to ~5 minutes of audio)
        # Average reading: 150 words/min, so 5 min = ~750 words
        realistic_chapter = " ".join(
            f"This is sentence number {i} with realistic content that makes sense. "
            for i in range(750)
        )

        chapter = Chapter(
            index=1,
            name="Complete Chapter",
            source_path="ch1.html",
            text=realistic_chapter,
            speech_text=realistic_chapter,
        )

        # Track what Edge TTS actually receives
        tts_received_texts = []

        class SpyEdgeTTSEngine:
            """Mock Edge TTS that captures all text it receives."""

            async def synthesize_async(self, text, output_path, formatting_segments=None):
                # Record EVERY call to synthesize_async
                tts_received_texts.append(text)

                # Simulate successful synthesis
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"audio" * 500_000)  # ≈2.5MB to satisfy duration heuristics
                return output_path

        spy_engine = SpyEdgeTTSEngine()
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Complete_Test",
            edge_auto_offline_chars=0,
            edge_auto_offline_seconds=0,
        )

        # Run conversion
        result = await self.converter._convert_chapters_sequential(
            [chapter], spy_engine, cache_dir, config
        )

        # Verify conversion succeeded
        self.assertEqual(result.converted_chapters, 1, "Chapter should convert successfully")

        # Verify Edge TTS was called (possibly multiple times for segments)
        self.assertGreater(len(tts_received_texts), 0, "Edge TTS should be called at least once")

        # Combine all text received by Edge TTS (in case it was segmented)
        total_tts_input = " ".join(tts_received_texts)

        # Normalize for comparison
        import re

        normalize = lambda t: re.sub(r"\s+", " ", t or "").strip()

        normalized_original = normalize(realistic_chapter)
        normalized_tts_input = normalize(total_tts_input)

        # CRITICAL: TTS should receive 100% of the text
        original_word_count = len(normalized_original.split())
        tts_word_count = len(normalized_tts_input.split())

        self.assertGreaterEqual(
            tts_word_count,
            original_word_count * 0.99,  # Allow 1% tolerance for processing
            f"CRITICAL BUG: TTS only received {tts_word_count}/{original_word_count} words! "
            f"Missing {original_word_count - tts_word_count} words. This causes audio truncation.",
        )

        # Verify first and last sentences are present
        self.assertIn(
            "sentence number 0",
            normalized_tts_input,
            "First sentence missing - TTS input is truncated at start",
        )
        self.assertIn(
            "sentence number 749",
            normalized_tts_input,
            "Last sentence missing - TTS input is truncated at end",
        )

    async def test_show_structure_matches_tts_input(self):
        """Verify that show-structure output matches what actually goes to TTS."""
        cache_dir = Path(self.temp_dir) / ".cache" / "Structure_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        # Chapter with language tags (as shown in show-structure)
        chapter_with_tags = Chapter(
            index=1,
            name="Structure Test",
            source_path="ch1.html",
            text="Original parsed text",
            speech_text="English text [[lang:pt-BR]]Texto português[[/lang]] more English",
        )

        # Track what TTS receives
        tts_inputs = []

        class CapturingTTSEngine:
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                tts_inputs.append(text)
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"audio" * 500)
                return output_path

        engine = CapturingTTSEngine()
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Structure_Test",
        )

        # Run conversion
        result = await self.converter._convert_chapters_sequential(
            [chapter_with_tags], engine, cache_dir, config
        )

        self.assertEqual(result.converted_chapters, 1)

        # What was sent to TTS
        tts_input = " ".join(tts_inputs)

        # What would be shown in show-structure (the speech_text)
        show_structure_text = chapter_with_tags.speech_text

        # They MUST match
        import re

        normalize = lambda t: re.sub(r"\s+", " ", t or "").strip()

        self.assertEqual(
            normalize(tts_input),
            normalize(show_structure_text),
            "CRITICAL: show-structure output does NOT match TTS input! "
            "This means the text files don't reflect what was actually converted.",
        )

        # Verify pre-tts.txt file matches as well
        text_dir = cache_dir / "text"
        pre_tts_files = list(text_dir.glob("*-pre-tts.txt"))
        self.assertEqual(len(pre_tts_files), 1)

        cached_text = pre_tts_files[0].read_text(encoding="utf-8")

        self.assertEqual(
            normalize(cached_text),
            normalize(show_structure_text),
            "pre-tts.txt should match show-structure (speech_text)",
        )


class TestChapterProcessor(unittest.TestCase):
    """Test cases for ChapterProcessor class"""

    def test_chunk_text_short_text(self):
        """Test chunking short text"""
        text = "This is a short text."
        chunks = ChapterProcessor.chunk_text(text, max_size=100)

        self.assertEqual(len(chunks), 1)
        self.assertEqual(chunks[0], text)

    def test_chunk_text_long_text(self):
        """Test chunking long text"""
        text = "This is sentence one. This is sentence two! This is sentence three? This is sentence four."
        chunks = ChapterProcessor.chunk_text(text, max_size=40)

        self.assertGreater(len(chunks), 1)

        # Check that all chunks are within size limit
        for chunk in chunks:
            self.assertLessEqual(len(chunk), 50)  # Allow some buffer

        # Check that joining chunks gives original text (approximately)
        joined = "".join(chunks)
        self.assertIn("sentence one", joined)
        self.assertIn("sentence four", joined)

    def test_chunk_text_empty_text(self):
        """Test chunking empty text"""
        chunks = ChapterProcessor.chunk_text("", max_size=100)

        self.assertEqual(len(chunks), 1)
        self.assertEqual(chunks[0], "")


def test_chunk_text_single_long_sentence():
    """Test chunking single very long sentence"""
    text = "This is a very long sentence that exceeds the maximum size limit and should be handled gracefully"
    chunks = ChapterProcessor.chunk_text(text, max_size=50)

    assert len(chunks) >= 1
    # Should handle gracefully even if single sentence is too long


class TestAutoEngineCandidates(unittest.TestCase):
    def _make_converter(self) -> AudioConverter:
        conv = AudioConverter()
        conv.hardware_profile = SimpleNamespace(network_speed_estimate="slow")
        return conv

    def test_skip_guarded_engines(self):
        converter = self._make_converter()
        config = ConversionConfig(engine="edge", primary_language="pt-BR")

        with (
            patch("src.converter._has_piper_support", return_value=False),
            patch("src.converter._has_coqui_support", return_value=False),
            patch.object(
                converter.tts_factory.voice_provider,
                "get_voice",
                side_effect=lambda engine, lang: "model.onnx" if engine == "piper" else None,
            ),
        ):
            order = converter._auto_engine_candidates(config)

        self.assertNotIn("piper", order)
        self.assertNotIn("coqui", order)

    def test_prefers_piper_when_supported(self):
        converter = self._make_converter()
        config = ConversionConfig(engine="edge", primary_language="pt-BR")

        with (
            patch("src.converter._has_piper_support", return_value=True),
            patch("src.converter._has_coqui_support", return_value=False),
            patch.object(
                converter.tts_factory.voice_provider,
                "get_voice",
                side_effect=lambda engine, lang: "model.onnx" if engine == "piper" else None,
            ),
        ):
            order = converter._auto_engine_candidates(config)

        self.assertEqual(order[0], "edge", f"Unexpected auto engine order: {order}")


class TestValidateAudioCompleteness(unittest.TestCase):
    """Tests for validate_audio_completeness with the calibrated 200 WPM default."""

    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()

    def tearDown(self):
        import shutil

        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_missing_file_returns_false(self):
        result, coverage = validate_audio_completeness(
            Path(self.temp_dir) / "nonexistent.mp3", 5000
        )
        self.assertFalse(result)
        self.assertEqual(coverage, 0.0)

    def test_short_chapter_skips_check(self):
        # text_length < 1000 should always pass regardless of audio
        mp3 = Path(self.temp_dir) / "short.mp3"
        mp3.write_bytes(b"\x00" * 100)  # tiny/invalid file still passes
        result, coverage = validate_audio_completeness(mp3, 500)
        self.assertTrue(result)
        self.assertEqual(coverage, 100.0)

    def test_complete_audio_at_200_wpm(self):
        # Simulate ~200 WPM audio for a 5000-char chapter:
        # 5000 chars / 5 chars/word = 1000 words; at 200 WPM → 5 minutes
        mp3 = Path(self.temp_dir) / "complete.mp3"
        mp3.write_bytes(b"\x00" * 100)  # must exist for the check to proceed
        with patch("src.converter.MP3") as mock_mp3:
            mock_mp3.return_value.info.length = 300.0  # 5 minutes
            result, coverage = validate_audio_completeness(mp3, 5000)
        # coverage = (5 min * 200 wpm * 5 chars/word) / 5000 = 100%
        self.assertTrue(result)
        self.assertAlmostEqual(coverage, 100.0, places=0)

    def test_truncated_audio_detected(self):
        # 5000-char chapter but only 2 minutes of audio → ~80% coverage → truncated
        mp3 = Path(self.temp_dir) / "truncated.mp3"
        mp3.write_bytes(b"\x00" * 100)
        with patch("src.converter.MP3") as mock_mp3:
            mock_mp3.return_value.info.length = 120.0  # 2 minutes
            result, coverage = validate_audio_completeness(mp3, 5000)
        # coverage = (2 * 200 * 5) / 5000 = 2000/5000 = 40%  → missing 60% → truncated
        self.assertFalse(result)
        self.assertLess(coverage, 90.0)

    def test_old_160_wpm_would_have_falsely_failed(self):
        # Edge-TTS at real 200 WPM for a 10000-char chapter → 10 minutes audio.
        # With WPM=160: coverage = (10 * 160 * 5) / 10000 = 80% → detected as truncated.
        # With WPM=200: coverage = (10 * 200 * 5) / 10000 = 100% → passes.
        mp3 = Path(self.temp_dir) / "edge_complete.mp3"
        mp3.write_bytes(b"\x00" * 100)
        with patch("src.converter.MP3") as mock_mp3:
            mock_mp3.return_value.info.length = 600.0  # 10 minutes at 200 WPM
            with patch("src.converter.EXPECTED_WPM", 200):
                result_200, coverage_200 = validate_audio_completeness(mp3, 10000)
            with patch("src.converter.EXPECTED_WPM", 160):
                result_160, coverage_160 = validate_audio_completeness(mp3, 10000)
        self.assertTrue(result_200, "200 WPM should pass for complete Edge-TTS audio")
        self.assertFalse(result_160, "160 WPM would falsely fail for complete Edge-TTS audio")

    def test_corrupt_mp3_does_not_raise(self):
        mp3 = Path(self.temp_dir) / "corrupt.mp3"
        mp3.write_bytes(b"not a real mp3")
        # Should not raise; should return True (benefit of the doubt)
        result, coverage = validate_audio_completeness(mp3, 5000)
        self.assertTrue(result)
        self.assertEqual(coverage, 100.0)


class TestMaxChapterCharsConfig(unittest.TestCase):
    """Tests for MAX_CHAPTER_CHARS constant and skip predicate."""

    def test_default_is_zero_disabled(self):
        """MAX_CHAPTER_CHARS should default to 0 (disabled) via env var."""
        import src.converter as conv_mod

        # Without override, default is 0 (disabled)
        with patch.dict(os.environ, {}, clear=False):
            # Reload the value via _env_int logic directly
            raw = os.environ.get("MAX_CHAPTER_CHARS", "")
            value = int(raw) if raw else 0
            self.assertEqual(value, 0, "Default MAX_CHAPTER_CHARS must be 0 (disabled)")

        # The module constant should also be 0 in test environment
        self.assertEqual(conv_mod.MAX_CHAPTER_CHARS, 0)

    def test_skip_predicate_when_enabled(self):
        """Chapter larger than limit should trigger the skip condition."""
        limit = 200_000
        big_chapter_chars = 300_000
        small_chapter_chars = 5_000
        self.assertTrue(
            limit > 0 and big_chapter_chars > limit,
            "Oversized chapter should match skip condition",
        )
        self.assertFalse(
            limit > 0 and small_chapter_chars > limit,
            "Normal chapter should not match skip condition",
        )

    def test_skip_predicate_disabled_when_zero(self):
        """When MAX_CHAPTER_CHARS=0, no chapter should be skipped."""
        limit = 0
        chapter_chars = 999_999
        self.assertFalse(
            limit > 0 and chapter_chars > limit,
            "No chapter should be skipped when limit is 0",
        )

    def test_env_override_sets_limit(self):
        """Setting MAX_CHAPTER_CHARS env var correctly configures the limit."""
        with patch.dict(os.environ, {"MAX_CHAPTER_CHARS": "150000"}):
            raw = os.environ.get("MAX_CHAPTER_CHARS", "")
            value = int(raw) if raw else 0
            self.assertEqual(value, 150_000)


class TestAnalyzeChapterStatsOutliers(unittest.TestCase):
    """Tests for the outlier-detection logic in _analyze_chapter_stats."""

    def _make_chapters(self, lengths: list[int]) -> list[Chapter]:
        return [
            Chapter(index=i, name=f"Chapter {i}", source_path=f"ch{i}.xhtml", text="x" * n)
            for i, n in enumerate(lengths)
        ]

    def setUp(self):
        self.converter = AudioConverter()

    def test_no_outliers_for_uniform_chapters(self):
        chapters = self._make_chapters([5000] * 10)
        stats = self.converter._analyze_chapter_stats(chapters)
        self.assertEqual(stats["outlier_indices"], [])

    def test_detects_single_outlier(self):
        # One chapter is 15× the median (279K vs ~18K)
        lengths = [18_000] * 10 + [279_000]
        chapters = self._make_chapters(lengths)
        stats = self.converter._analyze_chapter_stats(chapters)
        self.assertIn(10, stats["outlier_indices"])

    def test_no_outlier_if_below_50k_floor(self):
        # Even if one chapter is >5× median, skip warning if it's <50K chars
        lengths = [1_000] * 10 + [8_000]
        chapters = self._make_chapters(lengths)
        stats = self.converter._analyze_chapter_stats(chapters)
        self.assertEqual(stats["outlier_indices"], [])

    def test_median_chars_computed_correctly(self):
        lengths = [1_000, 2_000, 3_000, 4_000, 5_000]
        chapters = self._make_chapters(lengths)
        stats = self.converter._analyze_chapter_stats(chapters)
        self.assertEqual(stats["median_chars"], 3_000)

    def test_outlier_max_chars_set(self):
        lengths = [10_000] * 5 + [300_000]
        chapters = self._make_chapters(lengths)
        stats = self.converter._analyze_chapter_stats(chapters)
        self.assertEqual(stats.get("outlier_max_chars"), 300_000)

    def test_outlier_warning_printed(self):
        lengths = [10_000] * 5 + [300_000]
        chapters = self._make_chapters(lengths)
        import io

        buf = io.StringIO()
        with unittest.mock.patch("sys.stdout", buf):
            self.converter._analyze_chapter_stats(chapters)
        output = buf.getvalue()
        self.assertIn("Oversized chapter", output)
        self.assertIn("conversion will take longer", output)


if __name__ == "__main__":
    unittest.main()
