"""Runtime metrics scenarios sharing the original unittest fixture."""

from python_app.tests._converter_test_support import Path as Path
from python_app.tests._converter_test_support import json as json


class RuntimeMetricsCases:
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

    def test_save_adaptive_state_checkpoint_does_not_spam_runtime_metrics(self):
        path_dir = Path(self.temp_dir)
        self.converter._adaptive_checkpoint_enabled = True
        self.converter._last_output_dir = path_dir
        for _ in range(5):
            self.converter._save_adaptive_state_checkpoint(path_dir)
        metrics_path = path_dir / "_runtime_metrics.jsonl"
        if metrics_path.exists():
            lines = metrics_path.read_text(encoding="utf-8").splitlines()
            self.assertFalse(
                any("adaptive_state_saved" in line for line in lines),
                "adaptive_state_saved event should not be emitted to runtime metrics",
            )

    def test_runtime_metrics_summary_includes_optimization_metrics(self):
        metrics_path = Path(self.temp_dir) / "_runtime_metrics.jsonl"
        events = [
            {"event": "prefetch_request", "chapter": 1},
            {"event": "prefetch_hit", "chapter": 1},
            {"event": "auto_ab_exploration", "chapter": 1, "engine": "piper"},
            {"event": "resource_budget_cap", "engine": "edge"},
            {"event": "adaptive_state_restored"},
            {
                "event": "runtime_profile",
                "limits": {"chapter_parallel_effective": 2},
            },
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
        self.assertEqual(payload["runtime_profile"]["limits"]["chapter_parallel_effective"], 2)

    def test_runtime_metric_dedupes_repeated_budget_caps(self):
        metrics_path = Path(self.temp_dir) / "_runtime_metrics.jsonl"
        self.converter._last_output_dir = Path(self.temp_dir)
        self.converter._append_runtime_metric(
            {
                "event": "resource_budget_cap",
                "engine": "edge",
                "from_parallel": 4,
                "to_parallel": 3,
                "reason": "ram_available",
                "ts": 100.0,
            }
        )
        self.converter._append_runtime_metric(
            {
                "event": "resource_budget_cap",
                "engine": "edge",
                "from_parallel": 4,
                "to_parallel": 3,
                "reason": "ram_available",
                "ts": 104.0,
            }
        )
        self.converter._append_runtime_metric(
            {
                "event": "resource_budget_cap",
                "engine": "edge",
                "from_parallel": 4,
                "to_parallel": 3,
                "reason": "ram_available",
                "ts": 120.0,
            }
        )
        lines = metrics_path.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 2)

    def test_runtime_metric_keeps_distinct_thermal_caps(self):
        metrics_path = Path(self.temp_dir) / "_runtime_metrics.jsonl"
        self.converter._last_output_dir = Path(self.temp_dir)
        self.converter._append_runtime_metric(
            {
                "event": "thermal_guard_cap",
                "mode": "normal",
                "from_parallel": 9,
                "to_parallel": 8,
                "ts": 200.0,
            }
        )
        self.converter._append_runtime_metric(
            {
                "event": "thermal_guard_cap",
                "mode": "critical",
                "from_parallel": 8,
                "to_parallel": 4,
                "ts": 201.0,
            }
        )
        lines = metrics_path.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 2)

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
