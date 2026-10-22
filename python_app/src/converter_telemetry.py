# -*- coding: utf-8 -*-
"""Chapter progress, checkpoints and bounded runtime telemetry."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, Optional

from .config import ConversionConfig
from .ebook_reader import Chapter


class ConverterTelemetry:
    """Chapter progress, checkpoints and bounded runtime telemetry."""

    def _record_chapter_progress(
        self, chapter: Chapter, success: bool, error: Optional[str] = None
    ):
        """Record chapter progress for adaptive adjustment."""
        if not self._adaptive_controller:
            return

        try:
            # Estimate chapter characters
            text = self._speech_text(chapter)
            chars_processed = len(text) if text else 0

            # Detect throttling by keyword in error
            throttled = (
                error and ("throttl" in error.lower() or "rate limit" in error.lower())
                if error
                else False
            )

            self._adaptive_controller.record_chapter_completion(
                chars_processed=chars_processed,
                success=success,
                error=error,
                throttled=throttled,
            )

            # Check if adjustment needed
            adjustment = self._adaptive_controller.calculate_adjustment()
            if adjustment.action != "no_change":
                self._adaptive_controller.apply_adjustment(adjustment)

        except Exception as exc:
            if self.verbose:
                print(f"⚠️  Error recording adaptive progress: {exc}")

    def _save_conversion_checkpoint(
        self,
        chapter_num: int,
        output_dir: Path,
        config: ConversionConfig,
        *,
        success: bool = True,
    ) -> None:
        """Save a conversion checkpoint after every N successful chapters.

        The checkpoint records which chapter indices have been completed so that
        a subsequent run can skip them via _split_cached_chapters (MP3 detection)
        and print a resume notice to the user.
        """
        if not success:
            return
        self._checkpoint_done_set.add(chapter_num)
        count = len(self._checkpoint_done_set)
        if count % self._checkpoint_interval != 0 and count != self._checkpoint_total:
            return
        if not self._current_book_path:
            return
        try:
            self.cache_manager.save_checkpoint(
                book_path=self._current_book_path,
                book_title=getattr(config, "book_title", "") or "",
                output_dir=output_dir,
                temp_dir=self._setup_temp_directory(config),
                total_chapters=self._checkpoint_total,
                completed_chapters=sorted(self._checkpoint_done_set),
                current_chapter=chapter_num,
                conversion_config={
                    "engine": getattr(config, "engine", ""),
                    "voice": getattr(config, "voice", ""),
                },
            )
        except Exception:
            pass  # Checkpoint is best-effort; never break a conversion

    def _runtime_metrics_path(self, output_dir: Optional[Path] = None) -> Optional[Path]:
        from . import converter as _runtime
        target_dir = output_dir or self._last_output_dir
        if not target_dir:
            return None
        try:
            target_dir = _runtime.Path(target_dir)
            target_dir.mkdir(parents=True, exist_ok=True)
            return target_dir / "_runtime_metrics.jsonl"
        except Exception:
            return None

    def _append_runtime_metric(
        self, payload: Dict[str, Any], output_dir: Optional[Path] = None
    ) -> None:
        from . import converter as _runtime
        path = self._runtime_metrics_path(output_dir)
        if path is None:
            return
        event = dict(payload or {})
        event.setdefault("ts", _runtime.time.time())
        if self._runtime_run_id:
            event.setdefault("run_id", self._runtime_run_id)
        if self._should_skip_runtime_metric(event):
            return
        try:
            self._rotate_runtime_metrics_if_needed(path)
            with path.open("a", encoding="utf-8") as handle:
                handle.write(_runtime.json.dumps(event, ensure_ascii=False) + "\n")
        except Exception:
            if self.verbose:
                print("⚠️ Failed to persist runtime metric")

    def _should_skip_runtime_metric(self, event: Dict[str, Any]) -> bool:
        """Drop high-frequency cap chatter that carries no new information."""
        from . import converter as _runtime
        name = str(event.get("event") or "")
        if name not in {"resource_budget_cap", "thermal_guard_cap"}:
            return False

        dedupe_fields = {
            "event": name,
            "engine": event.get("engine"),
            "mode": event.get("mode"),
            "from_parallel": event.get("from_parallel"),
            "to_parallel": event.get("to_parallel"),
            "reason": event.get("reason"),
        }
        now = float(event.get("ts") or _runtime.time.time())
        key = _runtime.json.dumps(dedupe_fields, sort_keys=True, ensure_ascii=False, default=str)
        previous = self._runtime_metric_dedupe.get(key)
        self._runtime_metric_dedupe[key] = {"ts": now}
        if previous is None:
            return False
        return (now - float(previous.get("ts") or 0.0)) < 15.0

    def _segment_metrics_path(self, output_dir: Optional[Path] = None) -> Optional[Path]:
        from . import converter as _runtime
        target_dir = output_dir or self._last_output_dir
        if not target_dir:
            return None
        try:
            base = _runtime.Path(target_dir)
            base.mkdir(parents=True, exist_ok=True)
            return base / "_segment_metrics.jsonl"
        except Exception:
            return None

    def _append_segment_metric(
        self, payload: Dict[str, Any], output_dir: Optional[Path] = None
    ) -> None:
        from . import converter as _runtime
        path = self._segment_metrics_path(output_dir)
        if path is None:
            return
        event = dict(payload or {})
        event.setdefault("ts", _runtime.time.time())
        if self._runtime_run_id:
            event.setdefault("run_id", self._runtime_run_id)
        try:
            self._rotate_runtime_metrics_if_needed(path, max_bytes=4_000_000)
            with path.open("a", encoding="utf-8") as handle:
                handle.write(_runtime.json.dumps(event, ensure_ascii=False) + "\n")
        except Exception:
            if self.verbose:
                print("⚠️ Failed to persist segment metric")

    def _attach_edge_metric_sink(self, engine: object, output_dir: Path) -> None:
        """Route Edge lifecycle records to this conversion's isolated metric file."""
        from . import converter as _runtime
        if engine is None:
            return
        previous = getattr(engine, "metric_callback", None)

        def _sink(payload: Dict[str, Any]) -> None:
            self._append_segment_metric(payload, output_dir=output_dir)
            if callable(previous):
                with _runtime.contextlib.suppress(Exception):
                    previous(payload)

        with _runtime.contextlib.suppress(Exception):
            setattr(engine, "metric_callback", _sink)

    def _eta_baseline_key_for_config(self, config: Optional[ConversionConfig]) -> str:
        cfg = config or self._active_config
        engine = str(getattr(cfg, "engine", "unknown") or "unknown").lower()
        book = str(getattr(cfg, "book_title", "") or "unknown").strip().lower()
        key = self._runtime_tuning_key(cfg, str(getattr(cfg, "engine", "unknown") or "unknown"))
        machine = str(key.get("machine_signature", "generic") or "generic")
        return f"{machine}|{engine}|{book}"

    def _load_eta_baseline(self, config: Optional[ConversionConfig]) -> float:
        from . import converter as _runtime
        key = self._eta_baseline_key_for_config(config)
        self._eta_baseline_key = key
        path = self._eta_baseline_path
        if not path.exists():
            return 0.0
        try:
            payload = _runtime.json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            return 0.0
        if not isinstance(payload, dict):
            return 0.0
        row = payload.get(key)
        if not isinstance(row, dict):
            return 0.0
        try:
            return max(0.0, float(row.get("chars_per_second", 0.0) or 0.0))
        except Exception:
            return 0.0

    def _save_eta_baseline(
        self, config: Optional[ConversionConfig], chars_per_second: float
    ) -> None:
        from . import converter as _runtime
        cps = max(0.0, float(chars_per_second or 0.0))
        if cps <= 1.0:
            return
        key = self._eta_baseline_key or self._eta_baseline_key_for_config(config)
        path = self._eta_baseline_path
        path.parent.mkdir(parents=True, exist_ok=True)
        payload: Dict[str, Any] = {}
        if path.exists():
            with _runtime.contextlib.suppress(Exception):
                loaded = _runtime.json.loads(path.read_text(encoding="utf-8"))
                if isinstance(loaded, dict):
                    payload.update(loaded)
        prev = payload.get(key) if isinstance(payload.get(key), dict) else {}
        prev_cps = float((prev or {}).get("chars_per_second", 0.0) or 0.0)
        blended = cps if prev_cps <= 0 else ((prev_cps * 0.65) + (cps * 0.35))
        payload[key] = {
            "chars_per_second": round(float(blended), 3),
            "updated_at": _runtime.time.time(),
            "samples": int(float((prev or {}).get("samples", 0) or 0) + 1),
        }
        with _runtime.contextlib.suppress(Exception):
            path.write_text(_runtime.json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
