# -*- coding: utf-8 -*-
"""Startup guardrails, canary sampling and effective profiles."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

from .config import ConversionConfig


class ConverterStartupPolicy:
    """Startup guardrails, canary sampling and effective profiles."""

    def _apply_startup_guardrail(self, config: Optional[ConversionConfig]) -> None:
        """Reduce aggressive settings when previous run regressed versus baseline."""
        from . import converter as _runtime
        if self._startup_guardrail_applied or not config:
            return
        if not _runtime._env_bool("STARTUP_GUARDRAIL_ENABLED", True):
            self._startup_guardrail_applied = True
            return
        threshold = max(5.0, _runtime._env_float("STARTUP_GUARDRAIL_DROP_PCT", 20.0))
        key = self._eta_baseline_key_for_config(config)
        path = self._startup_guardrail_path
        payload: Dict[str, Any] = {}
        if path.exists():
            with _runtime.contextlib.suppress(Exception):
                loaded = _runtime.json.loads(path.read_text(encoding="utf-8"))
                if isinstance(loaded, dict):
                    payload.update(loaded)
        row = payload.get(key) if isinstance(payload.get(key), dict) else {}
        baseline = float((row or {}).get("baseline_cps", 0.0) or 0.0)
        last = float((row or {}).get("last_cps", 0.0) or 0.0)
        self._startup_guardrail_applied = True
        if baseline <= 1.0 or last <= 1.0:
            return
        if last >= baseline * (1.0 - (threshold / 100.0)):
            return

        engine = (config.engine or "").lower()
        if engine == "piper":
            workers = max(
                1, int(getattr(config, "piper_max_procs", 0) or _runtime.os.getenv("PIPER_MAX_PROCS", "2"))
            )
            chunk = max(
                1800,
                int(
                    getattr(config, "piper_chunk_chars", 0)
                    or _runtime.os.getenv("PIPER_CHUNK_CHARS", "3000")
                ),
            )
            config.piper_max_procs = max(1, workers - 1)
            config.piper_chunk_chars = max(1800, chunk - 300)
            _runtime.os.environ["PIPER_MAX_PROCS"] = str(config.piper_max_procs)
            _runtime.os.environ["PIPER_CHUNK_CHARS"] = str(config.piper_chunk_chars)
        elif engine == "edge":
            config.edge_enable_parallel = False
            from ._server_engine_helpers import degrade_edge_chunk_chars

            config.edge_chunk_chars = degrade_edge_chunk_chars(
                getattr(config, "edge_chunk_chars", 12000) or 12000,
                floor=4000,
                cap=12000,
            )
            _runtime.os.environ["EDGE_CHUNK_CHARS"] = str(config.edge_chunk_chars)
        if getattr(config, "extra", None) is None:
            config.extra = {}
        config.extra["startup_guardrail"] = "1"
        self._append_runtime_metric(
            {
                "event": "startup_guardrail_applied",
                "baseline_cps": round(baseline, 3),
                "last_cps": round(last, 3),
                "threshold_pct": threshold,
                "engine": engine,
            },
            output_dir=self._last_output_dir,
        )

    def _update_startup_guardrail(
        self, config: Optional[ConversionConfig], chapter_cps: float
    ) -> None:
        from . import converter as _runtime
        cps = max(0.0, float(chapter_cps or 0.0))
        if cps <= 1.0:
            return
        key = self._eta_baseline_key_for_config(config)
        path = self._startup_guardrail_path
        path.parent.mkdir(parents=True, exist_ok=True)
        payload: Dict[str, Any] = {}
        if path.exists():
            with _runtime.contextlib.suppress(Exception):
                loaded = _runtime.json.loads(path.read_text(encoding="utf-8"))
                if isinstance(loaded, dict):
                    payload.update(loaded)
        row = payload.get(key) if isinstance(payload.get(key), dict) else {}
        prev_baseline = float((row or {}).get("baseline_cps", 0.0) or 0.0)
        baseline = cps if prev_baseline <= 0 else max(prev_baseline * 0.99, cps)
        payload[key] = {
            "baseline_cps": round(baseline, 3),
            "last_cps": round(cps, 3),
            "updated_at": _runtime.time.time(),
            "samples": int(float((row or {}).get("samples", 0) or 0) + 1),
        }
        with _runtime.contextlib.suppress(Exception):
            path.write_text(_runtime.json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    async def _maybe_run_piper_canary(
        self,
        *,
        tts_engine: object,
        config: Optional[ConversionConfig],
        chapter_text: str,
        output_dir: Path,
        chapter_index: int,
    ) -> None:
        """Probe two Piper profiles on a short sample and lock the best one."""
        from . import converter as _runtime
        if self._canary_profile_done:
            return
        if not _runtime._env_bool("STARTUP_CANARY_ENABLED", True):
            self._canary_profile_done = True
            return
        if not config or (config.engine or "").lower() != "piper":
            self._canary_profile_done = True
            return
        text = str(chapter_text or "").strip()
        if len(text) < 800:
            self._canary_profile_done = True
            return

        sample = text[: min(len(text), _runtime._env_int("STARTUP_CANARY_SAMPLE_CHARS", 1400))]
        base_workers = max(
            1,
            int(getattr(config, "piper_max_procs", 0) or _runtime.os.getenv("PIPER_MAX_PROCS", "2") or "2"),
        )
        base_chunk = max(
            1800,
            int(
                getattr(config, "piper_chunk_chars", 0)
                or _runtime.os.getenv("PIPER_CHUNK_CHARS", "3000")
                or "3000"
            ),
        )
        candidates = [
            (base_workers, base_chunk),
            (min(8, base_workers + 1), max(1800, base_chunk - 300)),
        ]
        if candidates[1] == candidates[0]:
            candidates = [candidates[0]]

        results: List[tuple[int, int, float]] = []
        for idx, (workers, chunk_chars) in enumerate(candidates):
            probe_path = output_dir / f"_canary_{chapter_index}_{idx}.wav"
            with _runtime.contextlib.suppress(Exception):
                probe_path.unlink(missing_ok=True)
            _runtime.os.environ["PIPER_MAX_PROCS"] = str(workers)
            _runtime.os.environ["PIPER_CHUNK_CHARS"] = str(chunk_chars)
            with _runtime.contextlib.suppress(Exception):
                setattr(tts_engine, "_semaphore", _runtime.asyncio.Semaphore(max(1, workers)))
            with _runtime.contextlib.suppress(Exception):
                setattr(tts_engine, "_chunk_char_limit", int(chunk_chars))
            started = _runtime.time.time()
            try:
                out = await tts_engine.synthesize_async(sample, probe_path)
            except Exception:
                out = None
            elapsed = max(0.001, _runtime.time.time() - started)
            if out is not None and _runtime.Path(out).exists():
                results.append((workers, chunk_chars, elapsed))
            with _runtime.contextlib.suppress(Exception):
                probe_path.unlink(missing_ok=True)

        if not results:
            self._canary_profile_done = True
            return
        best_workers, best_chunk, best_elapsed = min(results, key=lambda item: item[2])
        config.piper_max_procs = int(best_workers)
        config.piper_chunk_chars = int(best_chunk)
        _runtime.os.environ["PIPER_MAX_PROCS"] = str(best_workers)
        _runtime.os.environ["PIPER_CHUNK_CHARS"] = str(best_chunk)
        with _runtime.contextlib.suppress(Exception):
            setattr(tts_engine, "_semaphore", _runtime.asyncio.Semaphore(max(1, int(best_workers))))
        with _runtime.contextlib.suppress(Exception):
            setattr(tts_engine, "_chunk_char_limit", int(best_chunk))
        self._canary_profile_done = True
        self._append_runtime_metric(
            {
                "event": "startup_canary_selected",
                "chapter": chapter_index,
                "workers": int(best_workers),
                "chunk_chars": int(best_chunk),
                "elapsed_s": round(float(best_elapsed), 4),
                "candidates": len(results),
            },
            output_dir=output_dir,
        )
        if self.verbose:
            print(
                "🧪 Startup canary selected Piper profile: "
                f"workers={best_workers}, chunk={best_chunk} "
                f"(sample {best_elapsed:.2f}s)"
            )

    def _apply_detected_runtime_defaults(
        self,
        config: ConversionConfig,
        *,
        network_tier: str,
        auto_engine_pool: Optional[Dict[str, tuple[ConversionConfig, object]]] = None,
    ) -> None:
        """Apply HW/network driven defaults and propagate to runtime engine configs."""
        from . import converter as _runtime
        profile = self.hardware_profile
        cpu_physical = max(1, int(getattr(profile, "cpu_physical", 2) or 2))
        ram_total = float(getattr(profile, "ram_total_gb", 0.0) or 0.0)
        tier = (network_tier or "fast").strip().lower()

        targets: List[ConversionConfig] = [config]
        if auto_engine_pool:
            for pooled_config, _ in auto_engine_pool.values():
                if pooled_config is not None and pooled_config not in targets:
                    targets.append(pooled_config)

        for cfg in targets:
            engine_name = (cfg.engine or "").lower()
            if engine_name == "piper":
                if getattr(cfg, "piper_max_procs", None) is None:
                    piper_cap = max(1, min(4, cpu_physical))
                    if ram_total < 8:
                        piper_cap = min(piper_cap, 2)
                    if tier in {"slow", "medium"}:
                        piper_cap = max(1, min(piper_cap, max(1, cpu_physical // 2)))
                    cfg.piper_max_procs = piper_cap
                _runtime.os.environ.setdefault("PIPER_MAX_PROCS", str(max(1, int(cfg.piper_max_procs or 1))))
                _runtime.os.environ.setdefault(
                    "PIPER_CHUNK_CHARS",
                    str(2600 if ram_total < 8 else 3200),
                )

        if auto_engine_pool:
            for name, (pooled_config, engine_obj) in auto_engine_pool.items():
                engine_name = (name or "").lower()
                if engine_name == "piper" and engine_obj is not None:
                    target = max(1, int(getattr(pooled_config, "piper_max_procs", 1) or 1))
                    with _runtime.contextlib.suppress(Exception):
                        setattr(engine_obj, "_semaphore", _runtime.asyncio.Semaphore(target))

    def _record_effective_runtime_profile(
        self,
        *,
        config: ConversionConfig,
        edge_engine: Optional[object],
        chapter_parallel_count: int,
        network_tier: str,
        edge_cap: int,
        output_dir: Optional[Path] = None,
        cap_reasons: Optional[Iterable[str]] = None,
    ) -> None:
        """Persist the applied runtime profile once, without exposing sensitive config."""
        from . import converter as _runtime
        run_id = str(self._runtime_run_id or "")
        if run_id and getattr(self, "_runtime_profile_recorded_run_id", "") == run_id:
            return

        def _as_int(value: Any, default: int = 0) -> int:
            try:
                return int(value)
            except (TypeError, ValueError):
                return default

        def _as_float(value: Any, default: float = 0.0) -> float:
            try:
                return float(value)
            except (TypeError, ValueError):
                return default

        profile = self.hardware_profile
        cpu_logical = _as_int(getattr(profile, "cpu_count", 0) or _runtime.os.cpu_count() or 0)
        cpu_physical = _as_int(getattr(profile, "cpu_physical", 0) or 0)
        ram_total = _as_float(getattr(profile, "ram_total_gb", 0.0) or 0.0)
        ram_available = _as_float(getattr(profile, "ram_available_gb", 0.0) or 0.0)
        tier = str(network_tier or getattr(profile, "network_speed_estimate", "unknown"))
        tier = tier.strip().lower() or "unknown"

        tuner = getattr(edge_engine, "_network_tuner", None)
        stats = getattr(tuner, "stats", None)
        requests = _as_int(getattr(stats, "requests", 0) or 0)
        successes = _as_int(getattr(stats, "successes", 0) or 0)
        failures = _as_int(getattr(stats, "failures", 0) or 0)
        total_latency = _as_float(getattr(stats, "total_latency", 0.0) or 0.0)
        network_summary = {
            "tier": tier,
            "requests": requests,
            "successes": successes,
            "failures": failures,
            "rate_limits": _as_int(getattr(stats, "rate_limits", 0) or 0),
            "timeouts": _as_int(getattr(stats, "timeouts", 0) or 0),
            "avg_latency_s": round(total_latency / requests, 4) if requests else 0.0,
        }

        active_segment_getter = getattr(edge_engine, "_active_segment_seconds", None)
        active_segment_seconds = (
            active_segment_getter()
            if callable(active_segment_getter)
            else getattr(edge_engine, "_max_segment_seconds", None)
            or getattr(config, "edge_max_segment_seconds", 0)
            or 0.0
        )
        edge_limits = {
            "chunk_chars": _as_int(
                getattr(edge_engine, "_chunk_char_limit", None)
                or getattr(config, "edge_chunk_chars", 0)
                or 0
            ),
            "max_segment_seconds": _as_float(
                getattr(edge_engine, "_max_segment_seconds", None)
                or getattr(config, "edge_max_segment_seconds", 0)
                or 0.0
            ),
            "active_segment_seconds": _as_float(active_segment_seconds),
            "adaptive_segment_seconds": bool(
                getattr(config, "edge_adaptive_segment_seconds", False)
            ),
            "adaptive_segment_max_seconds": _as_float(
                getattr(config, "edge_adaptive_segment_max_seconds", 0) or 0.0
            ),
            "enable_parallel": bool(
                getattr(
                    edge_engine, "_enable_parallel", getattr(config, "edge_enable_parallel", True)
                )
            ),
            "parallel_slots": _as_int(getattr(edge_engine, "_parallel_slots", 0) or 0),
            "configured_max_concurrency": _as_int(getattr(config, "edge_max_concurrency", 0) or 0),
            "request_concurrency_cap": _as_int(edge_cap or 0),
            "safe_profile": dict(self._edge_auto_state.get("safe_profile") or {}),
        }
        limits = {
            "chapter_parallel_effective": max(1, _as_int(chapter_parallel_count or 1, 1)),
            "chapter_parallel_state_current": _as_int(
                self._parallel_state.get("current") or chapter_parallel_count or 1
            ),
            "edge": edge_limits,
            "piper_max_procs": _as_int(getattr(config, "piper_max_procs", 0) or 0),
            "piper_chunk_chars": _as_int(getattr(config, "piper_chunk_chars", 0) or 0),
        }

        thermal_state = getattr(self, "_thermal_guard_state", {}) or {}
        thermal_mode = str(thermal_state.get("mode", "normal") or "normal")
        thermal_cap = thermal_state.get("cap")
        reasons = {
            str(reason).strip().lower() for reason in (cap_reasons or []) if str(reason).strip()
        }
        if not reasons:
            if ram_total <= 8.5 or (ram_available and ram_available <= 2.5):
                reasons.add("ram")
            if tier in {"slow", "medium"}:
                reasons.add("network")
            if thermal_cap or thermal_mode != "normal":
                reasons.add("thermal")
            chapter_source = str(_runtime.os.getenv("CHAPTER_PARALLEL_COUNT_SOURCE", "") or "").strip()
            chapter_override = chapter_source == "explicit" or (
                not chapter_source
                and bool(str(_runtime.os.getenv("CHAPTER_PARALLEL_COUNT", "") or "").strip())
            )
            edge_source = str(_runtime.os.getenv("EDGE_MAX_CONCURRENCY_SOURCE", "") or "").strip()
            edge_override = edge_source == "explicit" or (
                not edge_source and bool(str(_runtime.os.getenv("EDGE_MAX_CONCURRENCY", "") or "").strip())
            )
            if chapter_override or edge_override:
                reasons.add("explicit_env")

        self._append_runtime_metric(
            {
                "event": "runtime_profile",
                "hardware": {
                    "cpu_logical": cpu_logical,
                    "cpu_physical": cpu_physical,
                    "ram_total_gb": round(ram_total, 3),
                    "ram_available_gb": round(ram_available, 3),
                    "os_type": str(getattr(profile, "os_type", "unknown") or "unknown"),
                },
                "network": network_summary,
                "max_performance": _runtime._env_bool("MAX_PERFORMANCE", True),
                "limits": limits,
                "thermal_power": {
                    "cap": _as_int(thermal_cap) if thermal_cap else None,
                    "mode": thermal_mode,
                },
                "cap_reasons": sorted(reasons),
            },
            output_dir=output_dir,
        )
        if run_id:
            self._runtime_profile_recorded_run_id = run_id
