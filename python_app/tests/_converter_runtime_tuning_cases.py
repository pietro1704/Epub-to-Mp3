"""Runtime tuning scenarios sharing the original unittest fixture."""

from python_app.tests._converter_test_support import (
    AudioConverter as AudioConverter,
    ConversionConfig as ConversionConfig,
    Mock as Mock,
    Path as Path,
    SimpleNamespace as SimpleNamespace,
    asyncio as asyncio,
    json as json,
    os as os,
    patch as patch,
    time as time,
)

class RuntimeTuningCases:
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

    def test_adaptive_state_checkpoint_roundtrip(self):
        path_dir = Path(self.temp_dir)
        self.converter._adaptive_checkpoint_enabled = True
        self.converter._segment_adaptive_state["pre_check_interval_by_engine"] = {"edge": 3}
        self.converter._segment_adaptive_state["segment_duration_policy"] = {
            "enabled": True,
            "target_seconds": 120.0,
            "hard_max_seconds": 180.0,
            "success_streak": 2,
        }
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
        self.assertEqual(
            other._segment_adaptive_state["segment_duration_policy"]["target_seconds"], 120.0
        )
        self.assertEqual(other._engine_resource_budget.get("edge", {}).get("cap"), 2)
        self.assertEqual(other._auto_ab_counter, 9)
