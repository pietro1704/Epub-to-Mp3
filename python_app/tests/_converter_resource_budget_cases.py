"""Resource budget scenarios sharing the original unittest fixture."""

from python_app.tests._converter_test_support import (
    ConversionConfig as ConversionConfig,
    Mock as Mock,
    Path as Path,
    ResourceSnapshot as ResourceSnapshot,
    SimpleNamespace as SimpleNamespace,
    json as json,
    os as os,
    patch as patch,
)

class ResourceBudgetCases:
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

    def test_engine_resource_budget_grows_ceiling_for_idle_edge(self):
        self.converter._resource_budget_enabled = True
        self.converter._parallel_state["ceiling"] = 8
        self.converter._parallel_state["current"] = 8
        self.converter._engine_resource_budget = {
            "edge": {"cap": 8, "pressure_streak": 0, "free_streak": 0}
        }
        snap = SimpleNamespace(cpu_percent=10.0, ram_gb=3.0)
        for _ in range(3):
            self.converter._apply_engine_resource_budget(
                engine_label="edge", snapshot=snap, engine_pool=None
            )
        self.assertGreater(self.converter._parallel_state["ceiling"], 8)
        self.assertGreater(self.converter._parallel_state["current"], 8)

    def test_engine_resource_budget_does_not_recover_under_ram_pressure(self):
        self.converter._resource_budget_enabled = True
        self.converter._parallel_state["ceiling"] = 4
        self.converter._parallel_state["current"] = 1
        self.converter._engine_resource_budget = {
            "edge": {"cap": 1, "pressure_streak": 0, "free_streak": 0}
        }
        pressure = ResourceSnapshot(cpu_percent=10.0, ram_gb=0.5)

        for _ in range(6):
            self.converter._apply_engine_resource_budget(
                engine_label="edge", snapshot=pressure, engine_pool=None
            )

        self.assertEqual(self.converter._parallel_state["current"], 1)
        self.assertEqual(self.converter._parallel_state["ceiling"], 4)

    def test_engine_resource_budget_emits_reason_coded_transition(self):
        self.converter._resource_budget_enabled = True
        self.converter._parallel_state["ceiling"] = 4
        self.converter._parallel_state["current"] = 4
        self.converter._append_runtime_metric = Mock()
        pressure = ResourceSnapshot(cpu_percent=10.0, ram_gb=0.5)

        with patch.dict(
            os.environ,
            {"CHAPTER_PARALLEL_COUNT": "7", "CHAPTER_PARALLEL_COUNT_SOURCE": "detected"},
            clear=False,
        ):
            for _ in range(2):
                self.converter._apply_engine_resource_budget(
                    engine_label="edge", snapshot=pressure, engine_pool=None
                )

        events = [call.args[0] for call in self.converter._append_runtime_metric.call_args_list]
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["event"], "resource_budget_cap")
        self.assertEqual(events[0]["reason"], "ram_available")
        self.assertFalse(events[0]["override_bypassed_guard"])

    def test_engine_resource_budget_reports_explicit_override_bypass(self):
        self.converter._resource_budget_enabled = True
        self.converter._parallel_state["ceiling"] = 4
        self.converter._parallel_state["current"] = 4
        self.converter._append_runtime_metric = Mock()
        pressure = ResourceSnapshot(cpu_percent=10.0, ram_gb=0.5)

        with patch.dict(
            os.environ,
            {"CHAPTER_PARALLEL_COUNT": "7", "CHAPTER_PARALLEL_COUNT_SOURCE": "explicit"},
            clear=False,
        ):
            for _ in range(2):
                self.converter._apply_engine_resource_budget(
                    engine_label="edge", snapshot=pressure, engine_pool=None
                )

        events = [call.args[0] for call in self.converter._append_runtime_metric.call_args_list]
        self.assertTrue(events[0]["override_bypassed_guard"])

    def test_effective_runtime_profile_records_applied_limits_and_cap_reasons(self):
        self.converter.hardware_profile = SimpleNamespace(
            cpu_count=8,
            cpu_physical=4,
            ram_total_gb=8.0,
            ram_available_gb=1.5,
            network_speed_estimate="medium",
            os_type="Darwin",
        )
        self.converter._thermal_guard_state = {"cap": 2, "mode": "thermal_warm"}
        self.converter._runtime_run_id = "run-profile-test"
        config = ConversionConfig(
            engine="edge",
            edge_chunk_chars=12000,
            edge_max_segment_seconds=85,
            edge_enable_parallel=True,
            edge_max_concurrency=12,
        )
        network_stats = SimpleNamespace(
            requests=4,
            successes=3,
            failures=1,
            rate_limits=1,
            timeouts=0,
            total_latency=6.0,
        )
        edge_engine = SimpleNamespace(
            _chunk_char_limit=8000,
            _max_segment_seconds=75.0,
            _parallel_slots=3,
            _enable_parallel=False,
            _network_tuner=SimpleNamespace(stats=network_stats),
        )

        self.converter._record_effective_runtime_profile(
            config=config,
            edge_engine=edge_engine,
            chapter_parallel_count=2,
            network_tier="medium",
            edge_cap=4,
            output_dir=Path(self.temp_dir),
            cap_reasons=["ram", "network", "thermal", "explicit_env"],
        )

        record = json.loads(
            (Path(self.temp_dir) / "_runtime_metrics.jsonl").read_text(encoding="utf-8")
        )
        self.assertEqual(record["event"], "runtime_profile")
        self.assertEqual(record["run_id"], "run-profile-test")
        self.assertEqual(record["hardware"]["cpu_physical"], 4)
        self.assertEqual(record["network"]["requests"], 4)
        self.assertEqual(record["limits"]["chapter_parallel_effective"], 2)
        self.assertEqual(record["limits"]["edge"]["chunk_chars"], 8000)
        self.assertEqual(record["limits"]["edge"]["max_segment_seconds"], 75.0)
        self.assertEqual(record["thermal_power"]["mode"], "thermal_warm")
        self.assertEqual(record["cap_reasons"], ["explicit_env", "network", "ram", "thermal"])

        self.converter._record_effective_runtime_profile(
            config=config,
            edge_engine=edge_engine,
            chapter_parallel_count=1,
            network_tier="slow",
            edge_cap=1,
            output_dir=Path(self.temp_dir),
        )
        self.assertEqual(
            len((Path(self.temp_dir) / "_runtime_metrics.jsonl").read_text().splitlines()), 1
        )
