"""Metrics presentation for the retained legacy CLI."""

from .cli_runtime_dependencies import Optional as Optional
from .cli_runtime_dependencies import Path as Path


class CLIMetricsPresentation:
    @staticmethod
    def _format_hms(seconds: float) -> str:
        total = max(0, int(seconds or 0))
        hours, rem = divmod(total, 3600)
        minutes, secs = divmod(rem, 60)
        parts: list[str] = []
        if hours:
            parts.append(f"{hours:02d}h")
        if minutes or hours:
            parts.append(f"{minutes:02d}m")
        parts.append(f"{secs:02d}s")
        return " ".join(parts)

    @staticmethod
    def _print_metrics_summary(temp_dir: Optional[Path], *, namespace) -> None:
        if not temp_dir:
            return
        summary_path = namespace.Path(temp_dir) / "metrics-summary.json"
        if not summary_path.exists():
            print("📊 Metrics summary: not found")
            return
        try:
            payload = namespace.json.loads(summary_path.read_text(encoding="utf-8"))
        except Exception as exc:
            print(f"⚠️ Metrics summary read failed: {exc}")
            return

        chapters = payload.get("chapters", {}) if isinstance(payload, dict) else {}
        total_events = payload.get("total_events", 0) if isinstance(payload, dict) else 0
        print("\n📊 Runtime metrics summary")
        print(f"   events: {total_events}")
        print(
            "   chapters: "
            f"{chapters.get('successful', 0)}/{chapters.get('total', 0)} ok, "
            f"{chapters.get('failed', 0)} failed"
        )
        optimization = payload.get("optimization_metrics", {}) if isinstance(payload, dict) else {}
        if isinstance(optimization, dict) and optimization:
            print(
                "   optimization: "
                f"prefetch_hit_rate={float(optimization.get('prefetch_hit_rate', 0.0) or 0.0) * 100:.1f}% | "
                f"ab_explorations={int(optimization.get('ab_explorations', 0) or 0)} | "
                f"budget_caps={int(optimization.get('budget_caps_applied', 0) or 0)} | "
                f"adaptive_restores={int(optimization.get('adaptive_state_restores', 0) or 0)}"
            )
        seg_summary_path = namespace.Path(temp_dir) / "segment-metrics-summary.json"
        if seg_summary_path.exists():
            try:
                seg_payload = namespace.json.loads(seg_summary_path.read_text(encoding="utf-8"))
                engines = seg_payload.get("engines", {}) if isinstance(seg_payload, dict) else {}
                if isinstance(engines, dict) and engines:
                    best_engine = None
                    best_cps = 0.0
                    for engine_name, row in engines.items():
                        if not isinstance(row, dict):
                            continue
                        avg = float(row.get("avg_chars_per_second", 0.0) or 0.0)
                        if avg > best_cps:
                            best_cps = avg
                            best_engine = str(engine_name)
                    if best_engine:
                        print(
                            f"   segments: best_engine={best_engine} avg_chars_per_second={best_cps:.1f}"
                        )
            except Exception:
                pass
        rec_path = namespace.Path(temp_dir) / "metrics-recommendations.txt"
        if rec_path.exists():
            try:
                rec_lines = rec_path.read_text(encoding="utf-8").splitlines()
                recommendation = next(
                    (
                        line.strip()
                        for line in rec_lines
                        if line.strip().startswith("- ") and line.strip()
                    ),
                    "",
                )
                if recommendation:
                    print(f"   recommendation: {recommendation[2:]}")
            except Exception:
                pass
        print(f"   file: {summary_path}")

    @staticmethod
    def _print_metrics_dashboard_path(temp_dir: Optional[Path], *, namespace) -> None:
        if not temp_dir:
            return
        dashboard_path = namespace.Path(temp_dir) / "metrics-dashboard.html"
        if dashboard_path.exists():
            print(f"📈 Metrics dashboard: {dashboard_path}")
        else:
            print("📈 Metrics dashboard: not found")

    @staticmethod
    def _open_metrics_dashboard(temp_dir: Optional[Path], *, namespace) -> None:
        if not temp_dir:
            return
        dashboard_path = namespace.Path(temp_dir) / "metrics-dashboard.html"
        if not dashboard_path.exists():
            print("📈 Metrics dashboard: not found")
            return
        try:
            namespace.subprocess.Popen(
                ["open", str(dashboard_path)],
                stdout=namespace.subprocess.DEVNULL,
                stderr=namespace.subprocess.DEVNULL,
            )
            print(f"📈 Opened metrics dashboard: {dashboard_path}")
        except Exception as exc:
            print(f"⚠️ Could not open metrics dashboard: {exc}")
            print(f"   file: {dashboard_path}")

    @staticmethod
    def _export_metrics_bundle(temp_dir: Optional[Path], *, namespace) -> None:
        if not temp_dir:
            return
        base = namespace.Path(temp_dir)
        candidates = [
            "metrics-summary.json",
            "metrics-chapter-engine.csv",
            "metrics-dashboard.html",
            "segment-metrics-summary.json",
            "segment-metrics-engine-chapter.csv",
            "segment-metrics-dashboard.html",
            "metrics-recommendations.txt",
            "_runtime_metrics.jsonl",
            "_segment_metrics.jsonl",
            "_failure_checkpoint.json",
            "_adaptive_state_checkpoint.json",
        ]
        existing = [base / name for name in candidates if (base / name).exists()]
        if not existing:
            print("📦 Metrics bundle: no metric files found")
            return
        bundle_path = base / f"metrics-bundle-{int(namespace.time.time())}.zip"
        try:
            with namespace.zipfile.ZipFile(bundle_path, "w", compression=namespace.zipfile.ZIP_DEFLATED) as zf:
                for path in existing:
                    zf.write(path, arcname=path.name)
            print(f"📦 Metrics bundle: {bundle_path}")
        except Exception as exc:
            print(f"⚠️ Could not export metrics bundle: {exc}")
