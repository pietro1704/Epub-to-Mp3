"""Edge throttle, adaptive state, and resource budget mixin for AudioConverter."""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import platform
import re
import subprocess
import time
from pathlib import Path
from typing import Dict, List, Optional

import psutil

from .config import ConversionConfig
from .engine_pool import JobEnginePool, ResourceSnapshot


def _env_bool(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None or raw == "":
        return default
    try:
        return int(raw)
    except (TypeError, ValueError):
        return default


def _env_float(name: str, default: float) -> float:
    raw = os.getenv(name)
    if raw is None or raw == "":
        return default
    try:
        return float(raw)
    except (TypeError, ValueError):
        return default


# Mirror of the same constants defined in converter.py — evaluated from env vars
# so that runtime overrides (e.g. HF Spaces profile) are respected identically.
EDGE_MIN_CHARS_PER_SECOND = _env_float("EDGE_MIN_CHARS_PER_SECOND", 60.0)
EDGE_SAFE_CHUNK_CHARS = _env_int("EDGE_SAFE_CHUNK_CHARS", 10000)
EDGE_SAFE_MAX_SEGMENT_SECONDS = _env_float("EDGE_SAFE_MAX_SEGMENT_SECONDS", 300.0)
EDGE_SAFE_CHAPTER_PARALLEL = _env_int("EDGE_SAFE_CHAPTER_PARALLEL", 8)
EDGE_SAFE_TIMEOUT_MAX = _env_float("EDGE_SAFE_TIMEOUT_MAX", 3600.0)
STAGE_PIPELINE_ENABLED_DEFAULT = _env_bool("STAGE_PIPELINE_ENABLED", True)
STAGE_PIPELINE_DEPTH_DEFAULT = max(1, _env_int("STAGE_PIPELINE_DEPTH", 2))


class _EdgeThrottleMixin:
    def _apply_engine_resource_budget(
        self,
        *,
        engine_label: str,
        snapshot: ResourceSnapshot,
        engine_pool: Optional[JobEnginePool] = None,
    ) -> None:
        if not self._resource_budget_enabled:
            return
        engine = (engine_label or "unknown").lower()
        ceiling = max(1, int(self._parallel_state.get("ceiling") or 1))
        current = max(1, int(self._parallel_state.get("current") or 1))
        budget = self._engine_resource_budget.setdefault(
            engine,
            {"cap": ceiling, "pressure_streak": 0, "free_streak": 0},
        )
        cap = max(1, min(ceiling, int(budget.get("cap", ceiling) or ceiling)))
        engine_cps = self._segment_adaptive_state.get("engine_cps", {})
        if isinstance(engine_cps, dict) and engine_cps:
            averages: Dict[str, float] = {}
            for name, values in engine_cps.items():
                try:
                    seq = [float(v) for v in (values or []) if float(v) > 0]
                except Exception:
                    seq = []
                if seq:
                    averages[str(name).lower()] = sum(seq) / len(seq)
            if averages and engine in averages:
                top = max(averages.values()) or 1.0
                ratio = max(self._resource_budget_min_share, min(1.0, averages[engine] / top))
                perf_cap = max(1, int(round(ceiling * ratio)))
                cap = min(cap, perf_cap)

        if snapshot.cpu_percent > 94 or snapshot.ram_gb < 0.65:
            budget["pressure_streak"] = int(budget.get("pressure_streak", 0) or 0) + 1
            budget["free_streak"] = 0
            if budget["pressure_streak"] >= 2:
                cap = max(1, cap - 1)
                budget["pressure_streak"] = 0
        elif snapshot.cpu_percent < 72 and snapshot.ram_gb > 1.4:
            budget["free_streak"] = int(budget.get("free_streak", 0) or 0) + 1
            budget["pressure_streak"] = 0
            if budget["free_streak"] >= 3:
                cap = min(ceiling, cap + 1)
                budget["free_streak"] = 0
        else:
            budget["pressure_streak"] = 0
            budget["free_streak"] = 0

        budget["cap"] = cap
        if current > cap:
            self._parallel_state["current"] = cap
            if engine_pool is not None:
                engine_pool.update_parallel_slots(cap)
            self._append_runtime_metric(
                {
                    "event": "resource_budget_cap",
                    "engine": engine,
                    "from_parallel": current,
                    "to_parallel": cap,
                    "cpu_percent": round(float(snapshot.cpu_percent), 2),
                    "ram_gb": round(float(snapshot.ram_gb), 3),
                }
            )
            if self.verbose:
                print(f"⚖️ Resource budget cap for {engine}: {current}→{cap}")

    @staticmethod
    def _adaptive_state_path(temp_dir: Optional[Path]) -> Optional[Path]:
        if temp_dir is None:
            return None
        return Path(temp_dir) / "_adaptive_state_checkpoint.json"

    def _save_adaptive_state_checkpoint(self, temp_dir: Optional[Path]) -> None:
        if not self._adaptive_checkpoint_enabled:
            return
        path = self._adaptive_state_path(temp_dir)
        if path is None:
            return
        payload = {
            "saved_at": time.time(),
            "segment_adaptive_state": {
                "pre_check_interval_by_engine": dict(
                    self._segment_adaptive_state.get("pre_check_interval_by_engine", {}) or {}
                ),
                "pre_check_stable_streak_by_engine": dict(
                    self._segment_adaptive_state.get("pre_check_stable_streak_by_engine", {}) or {}
                ),
                "engine_cps": dict(self._segment_adaptive_state.get("engine_cps", {}) or {}),
                "last_adjustment": float(
                    self._segment_adaptive_state.get("last_adjustment", 0.0) or 0.0
                ),
            },
            "engine_resource_budget": dict(self._engine_resource_budget),
            "auto_ab_counter": int(self._auto_ab_counter or 0),
        }
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
            self._adaptive_checkpoint_dirty = 0
            self._append_runtime_metric({"event": "adaptive_state_saved"})
        except Exception:
            return

    def _load_adaptive_state_checkpoint(self, temp_dir: Optional[Path]) -> None:
        if not self._adaptive_checkpoint_enabled:
            return
        path = self._adaptive_state_path(temp_dir)
        if path is None or not path.exists():
            return
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            return
        if not isinstance(payload, dict):
            return
        seg = payload.get("segment_adaptive_state")
        if isinstance(seg, dict):
            for key in (
                "pre_check_interval_by_engine",
                "pre_check_stable_streak_by_engine",
                "engine_cps",
                "last_adjustment",
            ):
                if key in seg:
                    self._segment_adaptive_state[key] = seg.get(key)
        budget = payload.get("engine_resource_budget")
        if isinstance(budget, dict):
            self._engine_resource_budget = {
                str(name): dict(state) for name, state in budget.items() if isinstance(state, dict)
            }
        self._auto_ab_counter = int(payload.get("auto_ab_counter", self._auto_ab_counter) or 0)
        self._append_runtime_metric({"event": "adaptive_state_restored"})

    def _collect_engine_params(
        self, engine: str, cfg: Optional[ConversionConfig]
    ) -> Dict[str, object]:
        engine_name = (engine or "").lower()
        params: Dict[str, object] = {}
        if engine_name == "edge":
            params["edge_chunk_chars"] = int(getattr(cfg, "edge_chunk_chars", 12000) or 12000)
            params["edge_max_concurrency"] = int(
                os.getenv(
                    "EDGE_MAX_CONCURRENCY", str(getattr(cfg, "edge_max_concurrency", 12) or 12)
                )
            )
            params["edge_enable_parallel"] = bool(getattr(cfg, "edge_enable_parallel", True))
            params["edge_max_segment_seconds"] = int(
                getattr(cfg, "edge_max_segment_seconds", 85) or 85
            )
        elif engine_name == "coqui":
            params["coqui_chunk_chars"] = int(
                getattr(cfg, "coqui_chunk_chars", 1500)
                or os.getenv("COQUI_CHUNK_CHARS", "1500")
                or 1500
            )
            params["coqui_max_workers"] = int(
                getattr(cfg, "coqui_max_workers", 0) or os.getenv("COQUI_MAX_WORKERS", "2") or 2
            )
        elif engine_name == "piper":
            params["piper_max_procs"] = int(
                getattr(cfg, "piper_max_procs", 0) or os.getenv("PIPER_MAX_PROCS", "2") or 2
            )
            params["piper_chunk_chars"] = int(
                getattr(cfg, "piper_chunk_chars", 0)
                or os.getenv("PIPER_CHUNK_CHARS", "3000")
                or 3000
            )
        elif engine_name == "kokoro":
            params["kokoro_max_workers"] = int(os.getenv("KOKORO_MAX_WORKERS", "2") or 2)
            params["kokoro_chunk_chars"] = int(os.getenv("KOKORO_CHUNK_CHARS", "2000") or 2000)
        elif engine_name == "spark":
            params["spark_max_workers"] = int(os.getenv("SPARK_MAX_WORKERS", "1") or 1)
            params["spark_chunk_chars"] = int(os.getenv("SPARK_CHUNK_CHARS", "1500") or 1500)
        return params

    def _apply_runtime_feature_overrides(self, config: Optional[ConversionConfig]) -> None:
        """Apply per-run feature toggles from ConversionConfig.extra."""
        if config is None or not getattr(config, "extra", None):
            return
        extra = config.extra

        def _opt_bool(key: str) -> Optional[bool]:
            raw = extra.get(key)
            if raw is None:
                return None
            return str(raw).strip().lower() in {"1", "true", "yes", "on"}

        prefetch = _opt_bool("chapter_prefetch")
        if prefetch is not None:
            self._chapter_prefetch_enabled = prefetch
        auto_ab = _opt_bool("auto_ab")
        if auto_ab is not None:
            self._auto_ab_enabled = auto_ab
        checkpoint = _opt_bool("adaptive_checkpoint")
        if checkpoint is not None:
            self._adaptive_checkpoint_enabled = checkpoint
        stage_pipeline = _opt_bool("stage_pipeline")
        if stage_pipeline is not None:
            config.extra["stage_pipeline"] = "1" if stage_pipeline else "0"

    @staticmethod
    def _is_stage_pipeline_enabled(config: Optional[ConversionConfig]) -> bool:
        if config is None:
            return STAGE_PIPELINE_ENABLED_DEFAULT
        raw = getattr(config, "extra", {}).get("stage_pipeline")
        if raw is None:
            return STAGE_PIPELINE_ENABLED_DEFAULT
        return str(raw).strip().lower() in {"1", "true", "yes", "on"}

    @staticmethod
    def _stage_pipeline_depth(config: Optional[ConversionConfig]) -> int:
        raw = None if config is None else getattr(config, "extra", {}).get("stage_pipeline_depth")
        if raw is None:
            return STAGE_PIPELINE_DEPTH_DEFAULT
        try:
            return max(1, int(raw))
        except (TypeError, ValueError):
            return STAGE_PIPELINE_DEPTH_DEFAULT

    def _apply_engine_params(
        self,
        *,
        engine: str,
        cfg: Optional[ConversionConfig],
        params: Dict[str, object],
        engine_obj: Optional[object] = None,
    ) -> bool:
        engine_name = (engine or "").lower()
        changed = False
        if engine_name == "edge":
            chunk_chars = int(
                params.get("edge_chunk_chars", getattr(cfg, "edge_chunk_chars", 12000))
            )
            max_concurrency = int(
                params.get(
                    "edge_max_concurrency",
                    os.getenv(
                        "EDGE_MAX_CONCURRENCY", str(getattr(cfg, "edge_max_concurrency", 12))
                    ),
                )
            )
            enable_parallel = bool(
                params.get("edge_enable_parallel", getattr(cfg, "edge_enable_parallel", True))
            )
            max_segment_seconds = int(
                params.get("edge_max_segment_seconds", getattr(cfg, "edge_max_segment_seconds", 85))
            )
            if cfg is not None:
                cfg.edge_chunk_chars = chunk_chars
                cfg.edge_max_concurrency = max_concurrency
                cfg.edge_enable_parallel = enable_parallel
                cfg.edge_max_segment_seconds = max_segment_seconds
            os.environ["EDGE_CHUNK_CHARS"] = str(chunk_chars)
            os.environ["EDGE_MAX_CONCURRENCY"] = str(max_concurrency)
            os.environ["EDGE_MAX_SEGMENT_SECONDS"] = str(max_segment_seconds)
            if engine_obj is not None and hasattr(engine_obj, "apply_speed_profile"):
                with contextlib.suppress(Exception):
                    engine_obj.apply_speed_profile(
                        chunk_char_limit=max(4000, int(chunk_chars)),
                        max_segment_seconds=max(30.0, float(max_segment_seconds)),
                    )
            changed = True
        elif engine_name == "coqui":
            chunk_chars = int(
                params.get(
                    "coqui_chunk_chars",
                    getattr(cfg, "coqui_chunk_chars", 1500)
                    or os.getenv("COQUI_CHUNK_CHARS", "1500"),
                )
            )
            max_workers = int(
                params.get(
                    "coqui_max_workers",
                    getattr(cfg, "coqui_max_workers", 0) or os.getenv("COQUI_MAX_WORKERS", "2"),
                )
            )
            if cfg is not None:
                cfg.coqui_chunk_chars = chunk_chars
                cfg.coqui_max_workers = max_workers
            os.environ["COQUI_CHUNK_CHARS"] = str(chunk_chars)
            os.environ["COQUI_MAX_WORKERS"] = str(max_workers)
            if engine_obj is not None:
                with contextlib.suppress(Exception):
                    setattr(engine_obj, "_chunk_char_limit", chunk_chars)
            changed = True
        elif engine_name == "piper":
            max_procs = int(
                params.get(
                    "piper_max_procs",
                    getattr(cfg, "piper_max_procs", 0) or os.getenv("PIPER_MAX_PROCS", "2"),
                )
            )
            chunk_chars = int(
                params.get(
                    "piper_chunk_chars",
                    getattr(cfg, "piper_chunk_chars", 0) or os.getenv("PIPER_CHUNK_CHARS", "3000"),
                )
            )
            if cfg is not None:
                cfg.piper_max_procs = max_procs
                cfg.piper_chunk_chars = chunk_chars
            os.environ["PIPER_MAX_PROCS"] = str(max_procs)
            os.environ["PIPER_CHUNK_CHARS"] = str(chunk_chars)
            if engine_obj is not None:
                with contextlib.suppress(Exception):
                    setattr(engine_obj, "_chunk_char_limit", chunk_chars)
                with contextlib.suppress(Exception):
                    setattr(engine_obj, "_semaphore", asyncio.Semaphore(max(1, max_procs)))
            changed = True
        elif engine_name == "kokoro":
            os.environ["KOKORO_MAX_WORKERS"] = str(
                int(params.get("kokoro_max_workers", os.getenv("KOKORO_MAX_WORKERS", "2")))
            )
            os.environ["KOKORO_CHUNK_CHARS"] = str(
                int(params.get("kokoro_chunk_chars", os.getenv("KOKORO_CHUNK_CHARS", "2000")))
            )
            changed = True
        elif engine_name == "spark":
            os.environ["SPARK_MAX_WORKERS"] = str(
                int(params.get("spark_max_workers", os.getenv("SPARK_MAX_WORKERS", "1")))
            )
            os.environ["SPARK_CHUNK_CHARS"] = str(
                int(params.get("spark_chunk_chars", os.getenv("SPARK_CHUNK_CHARS", "1500")))
            )
            changed = True
        return changed

    def _apply_persisted_engine_params(
        self,
        *,
        cfg: Optional[ConversionConfig],
        engine_label: str,
        engine_obj: Optional[object] = None,
    ) -> bool:
        if not self._persist_best_params:
            return False
        key = self._runtime_tuning_key(cfg, engine_label)
        entry = self._best_param_store.get_profile(
            engine=key["engine"],
            voice=key["voice"],
            language=key["language"],
            machine_signature=key["machine_signature"],
        )
        if not entry:
            return False
        params = entry.get("params", {})
        if not isinstance(params, dict) or not params:
            return False
        changed = self._apply_engine_params(
            engine=key["engine"],
            cfg=cfg,
            params=params,
            engine_obj=engine_obj,
        )
        if changed and self.verbose:
            print(
                "⚡ Loaded best params "
                f"[{key['engine']}/{key['voice']}/{key['language']}] "
                f"({float(entry.get('best_chars_per_second', 0.0) or 0.0):.1f} chars/s)"
            )
        return changed

    def _persist_engine_params_after_chapter(
        self,
        *,
        cfg: Optional[ConversionConfig],
        engine_label: str,
        chapter_chars: int,
        elapsed_s: float,
        success: bool,
    ) -> None:
        if not self._persist_best_params or not success:
            return
        if chapter_chars < 1500 or elapsed_s <= 0:
            return
        cps = float(chapter_chars) / max(float(elapsed_s), 0.001)
        key = self._runtime_tuning_key(cfg, engine_label)
        params = self._collect_engine_params(key["engine"], cfg)
        if not params:
            return
        improved = self._best_param_store.upsert_profile(
            engine=key["engine"],
            voice=key["voice"],
            language=key["language"],
            machine_signature=key["machine_signature"],
            chars_per_second=cps,
            params=params,
        )
        if improved and self.verbose:
            print(
                "💾 Updated best params "
                f"[{key['engine']}/{key['voice']}/{key['language']}] -> {cps:.1f} chars/s"
            )

    def _record_segment_success(
        self,
        *,
        engine_label: str,
        chapter_index: int,
        segment_chars: int,
        engine_pool: Optional[JobEnginePool] = None,
        config: Optional[ConversionConfig] = None,
    ) -> None:
        """Adapt runtime parameters using successful segment/chunk telemetry."""
        engine = (engine_label or "").lower()
        if segment_chars <= 0:
            return

        state = self._segment_adaptive_state
        now = time.time()
        chapter_key = f"{engine}:{chapter_index}"
        chapter_times = state.setdefault("last_event_by_chapter", {})
        prev_ts = chapter_times.get(chapter_key)
        chapter_times[chapter_key] = now
        if prev_ts is None:
            return

        elapsed = max(now - float(prev_ts), 0.001)
        cps = float(segment_chars) / elapsed
        engine_cps = state.setdefault("engine_cps", {})
        history = engine_cps.setdefault(engine, [])
        history.append(cps)
        if len(history) > 16:
            del history[0 : len(history) - 16]
        avg_cps = sum(history) / len(history)
        snapshot = self._resource_snapshot()
        self._apply_thermal_power_guard(engine_pool=engine_pool)
        self._append_segment_metric(
            {
                "event": "segment_success",
                "engine": engine,
                "chapter": chapter_index,
                "segment_chars": int(segment_chars),
                "elapsed_s": round(float(elapsed), 4),
                "cps": round(float(cps), 3),
                "avg_cps": round(float(avg_cps), 3),
                "cpu_percent": round(float(snapshot.cpu_percent), 2),
                "ram_gb": round(float(snapshot.ram_gb), 3),
                "parallel": int(self._parallel_state.get("current") or 1),
            }
        )
        self._apply_engine_resource_budget(
            engine_label=engine,
            snapshot=snapshot,
            engine_pool=engine_pool,
        )

        # Reduce health-check overhead after sustained stability; restore immediately when unstable.
        base_interval = max(1, int(state.get("pre_check_base_interval", 1) or 1))
        max_interval = max(base_interval, int(state.get("pre_check_max_interval", 4) or 4))
        promote_streak = max(2, int(state.get("pre_check_promote_streak", 6) or 6))
        interval_by_engine = state.setdefault("pre_check_interval_by_engine", {})
        stable_by_engine = state.setdefault("pre_check_stable_streak_by_engine", {})
        current_interval = max(
            base_interval, int(interval_by_engine.get(engine, base_interval) or 1)
        )
        stable_streak = int(stable_by_engine.get(engine, 0) or 0)

        is_unstable = snapshot.cpu_percent > 95 or snapshot.ram_gb < 0.6 or avg_cps < 80
        if is_unstable:
            stable_by_engine[engine] = 0
            if current_interval != base_interval:
                interval_by_engine[engine] = base_interval
                if self.verbose:
                    print(
                        f"🩺 Pre-check interval reset for {engine}: {current_interval}→{base_interval}"
                    )
        else:
            stable_streak += 1
            if stable_streak >= promote_streak and current_interval < max_interval:
                interval_by_engine[engine] = min(max_interval, current_interval + 1)
                stable_by_engine[engine] = 0
                if self.verbose:
                    print(
                        f"⚡ Pre-check interval promoted for {engine}: "
                        f"{current_interval}→{interval_by_engine[engine]}"
                    )
            else:
                stable_by_engine[engine] = stable_streak

        cooldown = float(state.get("cooldown_seconds", 10.0) or 10.0)
        last_adjustment = float(state.get("last_adjustment", 0.0) or 0.0)
        if (now - last_adjustment) < cooldown:
            return

        current_parallel = max(1, int(self._parallel_state.get("current") or 1))
        ceiling_parallel = max(
            current_parallel, int(self._parallel_state.get("ceiling") or current_parallel)
        )
        new_parallel = current_parallel
        reason = None

        if snapshot.ram_gb < 0.45 and current_parallel > 1:
            state["down_streak"] = int(state.get("down_streak", 0) or 0) + 1
            state["up_streak"] = 0
            if state["down_streak"] >= 2:
                new_parallel = current_parallel - 1
                reason = f"segment telemetry: low RAM ({snapshot.ram_gb:.1f} GB)"
        elif snapshot.cpu_percent > 95 and avg_cps < 100 and current_parallel > 1:
            state["down_streak"] = int(state.get("down_streak", 0) or 0) + 1
            state["up_streak"] = 0
            if state["down_streak"] >= 2:
                new_parallel = current_parallel - 1
                reason = (
                    f"segment telemetry: CPU saturation ({int(snapshot.cpu_percent)}%) with low cps"
                )
        elif (
            snapshot.cpu_percent < 75
            and snapshot.ram_gb > 1.0
            and avg_cps > 170
            and current_parallel < ceiling_parallel
        ):
            state["up_streak"] = int(state.get("up_streak", 0) or 0) + 1
            state["down_streak"] = 0
            if state["up_streak"] >= 3:
                new_parallel = current_parallel + 1
                reason = f"segment telemetry: stable throughput (~{int(avg_cps)} chars/s)"
        else:
            state["up_streak"] = 0
            state["down_streak"] = 0

        new_parallel = max(1, min(ceiling_parallel, new_parallel))
        if new_parallel != current_parallel:
            self._parallel_state["current"] = new_parallel
            if engine_pool is not None:
                engine_pool.update_parallel_slots(new_parallel)
            state["last_adjustment"] = now
            state["up_streak"] = 0
            state["down_streak"] = 0
            if self.verbose and reason:
                print(f"⚙️ {reason} → {new_parallel} chapter(s) in parallel")
            return

        if not config:
            return

        tuned = False
        if engine == "piper":
            chunk_chars = int(os.getenv("PIPER_CHUNK_CHARS", "3000") or "3000")
            new_chunk = chunk_chars
            if avg_cps > 200 and snapshot.cpu_percent < 85:
                new_chunk = min(6000, chunk_chars + 300)
            elif avg_cps < 120 or snapshot.cpu_percent > 95:
                new_chunk = max(1800, chunk_chars - 300)
            if new_chunk != chunk_chars:
                os.environ["PIPER_CHUNK_CHARS"] = str(new_chunk)
                tuned = True
                if self.verbose:
                    print(f"⚙️ Piper adaptive chunk: {chunk_chars} → {new_chunk} (seg ok)")
            workers = int(
                getattr(config, "piper_max_procs", 0) or os.getenv("PIPER_MAX_PROCS", "2") or "2"
            )
            new_workers = workers
            if snapshot.cpu_percent > 95 or snapshot.ram_gb < 0.8:
                new_workers = max(1, workers - 1)
            elif avg_cps > 170 and snapshot.cpu_percent < 82 and snapshot.ram_gb > 1.4:
                new_workers = min(8, workers + 1)
            if new_workers != workers:
                os.environ["PIPER_MAX_PROCS"] = str(new_workers)
                config.piper_max_procs = new_workers
                tuned = True
                if self.verbose:
                    print(f"⚙️ Piper adaptive workers: {workers} → {new_workers} (seg ok)")
        elif engine == "coqui":
            chunk_chars = int(os.getenv("COQUI_CHUNK_CHARS", "1500") or "1500")
            new_chunk = chunk_chars
            if avg_cps > 120 and snapshot.cpu_percent < 88:
                new_chunk = min(4000, chunk_chars + 200)
            elif avg_cps < 70 or snapshot.cpu_percent > 95:
                new_chunk = max(900, chunk_chars - 200)
            if new_chunk != chunk_chars:
                os.environ["COQUI_CHUNK_CHARS"] = str(new_chunk)
                config.coqui_chunk_chars = new_chunk
                tuned = True
                if self.verbose:
                    print(f"⚙️ Coqui adaptive chunk: {chunk_chars} → {new_chunk} (seg ok)")
        elif engine == "edge":
            edge_chunk = int(os.getenv("EDGE_CHUNK_CHARS", "12000") or "12000")
            new_chunk = edge_chunk
            if avg_cps > 240 and snapshot.cpu_percent < 85:
                new_chunk = min(24000, edge_chunk + 500)
            elif avg_cps < 140 or snapshot.cpu_percent > 95:
                new_chunk = max(4000, edge_chunk - 500)
            if new_chunk != edge_chunk:
                os.environ["EDGE_CHUNK_CHARS"] = str(new_chunk)
                if config is not None:
                    config.edge_chunk_chars = new_chunk
                tuned = True
                if self.verbose:
                    print(f"⚙️ Edge adaptive chunk: {edge_chunk} → {new_chunk} (seg ok)")

        if tuned:
            state["last_adjustment"] = now

    def _pre_segment_health_check(
        self,
        *,
        engine_label: str,
        segment_chars: int,
        engine_pool: Optional[JobEnginePool] = None,
        config: Optional[ConversionConfig] = None,
        engine_obj: Optional[object] = None,
    ) -> None:
        """Run health checks before each segment and proactively adjust parameters."""
        engine = (engine_label or "").lower()
        if segment_chars <= 0:
            return
        state = self._segment_adaptive_state
        base_interval = max(1, int(state.get("pre_check_base_interval", 1) or 1))
        interval_by_engine = state.setdefault("pre_check_interval_by_engine", {})
        counter_by_engine = state.setdefault("pre_check_counter_by_engine", {})
        interval = max(base_interval, int(interval_by_engine.get(engine, base_interval) or 1))
        counter = int(counter_by_engine.get(engine, 0) or 0) + 1
        counter_by_engine[engine] = counter
        if interval > 1 and (counter % interval) != 1:
            return

        snapshot = self._resource_snapshot()
        self._apply_thermal_power_guard(engine_pool=engine_pool)
        self._append_segment_metric(
            {
                "event": "pre_segment_check",
                "engine": engine,
                "segment_chars": int(segment_chars),
                "cpu_percent": round(float(snapshot.cpu_percent), 2),
                "ram_gb": round(float(snapshot.ram_gb), 3),
                "parallel": int(self._parallel_state.get("current") or 1),
            }
        )
        self._apply_engine_resource_budget(
            engine_label=engine,
            snapshot=snapshot,
            engine_pool=engine_pool,
        )
        current_parallel = max(1, int(self._parallel_state.get("current") or 1))
        ceiling_parallel = max(
            current_parallel, int(self._parallel_state.get("ceiling") or current_parallel)
        )

        reduced_parallel = current_parallel
        if snapshot.ram_gb < 0.4 and current_parallel > 1:
            state["pre_reduce_streak"] = int(state.get("pre_reduce_streak", 0) or 0) + 1
            state["pre_hold_streak"] = 0
            if state["pre_reduce_streak"] >= 2:
                reduced_parallel = current_parallel - 1
        elif snapshot.cpu_percent > 97 and current_parallel > 1:
            state["pre_reduce_streak"] = int(state.get("pre_reduce_streak", 0) or 0) + 1
            state["pre_hold_streak"] = 0
            if state["pre_reduce_streak"] >= 2:
                reduced_parallel = current_parallel - 1
        else:
            state["pre_hold_streak"] = int(state.get("pre_hold_streak", 0) or 0) + 1
            if state["pre_hold_streak"] >= 2:
                state["pre_reduce_streak"] = 0

        reduced_parallel = max(1, min(ceiling_parallel, reduced_parallel))
        if reduced_parallel != current_parallel:
            self._parallel_state["current"] = reduced_parallel
            if engine_pool is not None:
                engine_pool.update_parallel_slots(reduced_parallel)
            state = self._segment_adaptive_state
            state["pre_reduce_streak"] = 0
            state["pre_hold_streak"] = 0
            if self.verbose:
                print(
                    f"🩺 Pre-segment check: reducing parallelism {current_parallel}→{reduced_parallel}"
                )

        if engine == "edge":
            if config is not None:
                chunk_chars = int(getattr(config, "edge_chunk_chars", 12000) or 12000)
                if snapshot.cpu_percent > 95 and segment_chars > 8000:
                    chunk_chars = max(4000, chunk_chars - 1000)
                elif snapshot.cpu_percent < 75 and segment_chars > 12000:
                    chunk_chars = min(24000, chunk_chars + 500)
                config.edge_chunk_chars = chunk_chars
                os.environ["EDGE_CHUNK_CHARS"] = str(chunk_chars)
            if engine_obj is not None and hasattr(engine_obj, "apply_speed_profile"):
                with contextlib.suppress(Exception):
                    engine_obj.apply_speed_profile(
                        chunk_char_limit=max(4000, int(getattr(config, "edge_chunk_chars", 12000))),
                    )
        elif engine == "piper":
            chunk_chars = int(os.getenv("PIPER_CHUNK_CHARS", "3000") or "3000")
            workers = int(
                getattr(config, "piper_max_procs", 0)
                if config is not None
                else 0 or os.getenv("PIPER_MAX_PROCS", "2") or "2"
            )
            if snapshot.cpu_percent > 95:
                chunk_chars = max(1800, chunk_chars - 300)
                workers = max(1, workers - 1)
            elif snapshot.cpu_percent < 75 and segment_chars > 6000:
                chunk_chars = min(6000, chunk_chars + 200)
                workers = min(8, workers + 1)
            os.environ["PIPER_CHUNK_CHARS"] = str(chunk_chars)
            os.environ["PIPER_MAX_PROCS"] = str(workers)
            if config is not None:
                config.piper_max_procs = workers
            if engine_obj is not None:
                with contextlib.suppress(Exception):
                    setattr(engine_obj, "_chunk_char_limit", chunk_chars)
                with contextlib.suppress(Exception):
                    setattr(engine_obj, "_semaphore", asyncio.Semaphore(max(1, workers)))
        elif engine == "coqui":
            chunk_chars = int(os.getenv("COQUI_CHUNK_CHARS", "1500") or "1500")
            if snapshot.cpu_percent > 95:
                chunk_chars = max(900, chunk_chars - 200)
            elif snapshot.cpu_percent < 75 and segment_chars > 6000:
                chunk_chars = min(4000, chunk_chars + 150)
            os.environ["COQUI_CHUNK_CHARS"] = str(chunk_chars)
            if config is not None:
                config.coqui_chunk_chars = chunk_chars

    def _resource_snapshot(self) -> ResourceSnapshot:
        """Return a best-effort resource snapshot for tuning."""
        cpu_pct = 0.0
        ram_gb = 0.0
        with contextlib.suppress(Exception):
            cpu_pct = float(psutil.cpu_percent(interval=None))
        with contextlib.suppress(Exception):
            mem = psutil.virtual_memory()
            ram_gb = float(mem.available / (1024**3))
        cpu_idle = max(0.0, 100.0 - cpu_pct)
        return ResourceSnapshot(
            cpu_percent=cpu_pct,
            cpu_idle=cpu_idle,
            ram_gb=ram_gb,
            active_jobs=1,
        )

    def _detect_macos_thermal_power_cap(self, ceiling: int) -> tuple[int, str]:
        """Return runtime parallel cap based on macOS power/thermal pressure."""
        if platform.system().lower() != "darwin":
            return ceiling, "normal"
        cap = int(max(1, ceiling))
        mode = "normal"
        try:
            batt = subprocess.run(
                ["pmset", "-g", "batt"],
                capture_output=True,
                text=True,
                timeout=2,
            )
            batt_out = str(batt.stdout or "").lower()
            on_battery = "battery power" in batt_out
            if on_battery:
                mode = "battery"
                cap = max(1, min(cap, int(round(ceiling * 0.7))))
        except Exception:
            pass
        try:
            therm = subprocess.run(
                ["pmset", "-g", "therm"],
                capture_output=True,
                text=True,
                timeout=2,
            )
            therm_out = str(therm.stdout or "")
            speed_limit = None
            match = re.search(r"CPU_Speed_Limit\\s*=\\s*(\\d+)", therm_out, flags=re.IGNORECASE)
            if match:
                speed_limit = int(match.group(1))
            if speed_limit is not None:
                if speed_limit < 75:
                    mode = "thermal_hot"
                    cap = max(1, min(cap, int(round(ceiling * 0.5))))
                elif speed_limit < 90:
                    if mode == "normal":
                        mode = "thermal_warm"
                    cap = max(1, min(cap, int(round(ceiling * 0.75))))
        except Exception:
            pass
        return max(1, cap), mode

    def _apply_thermal_power_guard(self, engine_pool: Optional[JobEnginePool] = None) -> None:
        """Continuously cap parallelism under thermal/power pressure."""
        state = self._thermal_guard_state
        now = time.time()
        poll_interval = float(state.get("poll_interval", 20.0) or 20.0)
        cached_cap = state.get("cap")
        mode = str(state.get("mode", "normal") or "normal")
        ceiling = max(1, int(self._parallel_state.get("ceiling") or 1))

        if (now - float(state.get("last_poll", 0.0) or 0.0)) >= poll_interval or cached_cap is None:
            cap, mode = self._detect_macos_thermal_power_cap(ceiling)
            state["last_poll"] = now
            state["cap"] = cap
            state["mode"] = mode
            cached_cap = cap

        if cached_cap is None:
            return
        cap_int = max(1, min(ceiling, int(cached_cap)))
        current = max(1, int(self._parallel_state.get("current") or 1))
        if current > cap_int:
            self._parallel_state["current"] = cap_int
            if engine_pool is not None:
                engine_pool.update_parallel_slots(cap_int)
            self._append_runtime_metric(
                {
                    "event": "thermal_guard_cap",
                    "mode": mode,
                    "from_parallel": current,
                    "to_parallel": cap_int,
                }
            )
            if self.verbose:
                print(f"🌡️ Thermal/power guard ({mode}): {current}→{cap_int}")

    def _auto_tune_parallelism(
        self,
        *,
        throughput: Optional[float],
        batch_errors: int,
    ) -> tuple[int, Optional[str]]:
        """Decide the next chapter parallelism level based on telemetry."""
        state = self._parallel_state or {}
        ceiling = max(1, int(state.get("ceiling") or 1))
        thermal_cap = self._thermal_guard_state.get("cap")
        if thermal_cap is not None:
            try:
                ceiling = max(1, min(ceiling, int(thermal_cap)))
            except (TypeError, ValueError):
                pass
        current = max(1, min(ceiling, int(state.get("current") or 1)))
        best = float(state.get("best_throughput") or 0.0)
        last = state.get("last_throughput")
        degrade_runs = int(state.get("degrade_runs") or 0)
        snapshot = self._resource_snapshot()
        cpu_pct = snapshot.cpu_percent
        ram_gb = snapshot.ram_gb
        reason: Optional[str] = None
        new_value = current

        if batch_errors > 0:
            new_value = max(1, current - 1)
            state["degrade_runs"] = min(3, degrade_runs + 1)
            reason = (
                f"reducing to {new_value} chapter(s) simultaneous after {batch_errors} error(s)"
            )
        else:
            state["degrade_runs"] = max(0, degrade_runs - 1)
            if throughput:
                if throughput > best:
                    state["best_throughput"] = throughput
                if last and throughput < last * 0.78 and current > 1:
                    new_value = current - 1
                    reason = (
                        f"throughput caiu de ~{int(last)} para ~{int(throughput)} chars/s → "
                        f"{new_value} chapter(s)"
                    )
                elif last and throughput >= last * 1.18 and current < ceiling:
                    new_value = current + 1
                    reason = (
                        f"throughput atingiu ~{int(throughput)} chars/s → "
                        f"testando {new_value} chapter(s)"
                    )
                elif not last and current < ceiling and throughput >= max(best, 1.0):
                    new_value = current + 1
                    reason = (
                        f"fast initial batch (~{int(throughput)} chars/s) → {new_value} chapter(s)"
                    )

            if not reason:
                if ram_gb < 0.45 and new_value > 1:
                    new_value = new_value - 1
                    reason = f"RAM livre baixa ({ram_gb:.1f} GB) → limitando a {new_value}"
                elif cpu_pct < 55.0 and new_value < ceiling:
                    new_value = new_value + 1
                    reason = f"CPU em {int(cpu_pct)}% → liberando {new_value} chapter(s)"
                elif cpu_pct > 94.0 and throughput and throughput < best * 0.85 and new_value > 1:
                    new_value = new_value - 1
                    reason = f"CPU saturada ({int(cpu_pct)}%) sem ganho → {new_value} chapter(s)"

        new_value = max(1, min(ceiling, new_value))
        if throughput:
            state["last_throughput"] = throughput
        elif "last_throughput" not in state:
            state["last_throughput"] = None
        state["current"] = new_value
        self._parallel_state = state
        return new_value, reason

    def _apply_edge_slow_mode(
        self,
        reason: str,
        *,
        engine_pool: Optional[JobEnginePool] = None,
        engine_obj: Optional[object] = None,
    ) -> bool:
        """Clamp Edge settings when latency/throughput indicates throttling."""
        state = self._edge_auto_state or {}
        if not state.get("enabled"):
            return False

        announce = not state.get("slow_mode")
        state["slow_mode"] = True
        state["slow_mode_reason"] = reason
        state["recovery_streak"] = 0
        safe_profile = state.get("safe_profile") or {}
        chunk_chars = int(safe_profile.get("chunk_chars") or EDGE_SAFE_CHUNK_CHARS)
        max_segment = float(
            safe_profile.get("max_segment_seconds") or EDGE_SAFE_MAX_SEGMENT_SECONDS
        )
        timeout_max = float(safe_profile.get("timeout_max") or EDGE_SAFE_TIMEOUT_MAX)
        cap = int(safe_profile.get("parallel_cap") or EDGE_SAFE_CHAPTER_PARALLEL)
        if state.get("parallel_cap"):
            with contextlib.suppress(TypeError, ValueError):
                cap = min(cap, int(state["parallel_cap"]))
        state["parallel_cap"] = max(1, cap)
        fast_profiles = state.setdefault("fast_profiles", {})
        for cfg in state.get("configs") or []:
            if (cfg.engine or "").lower() != "edge":
                continue
            fast_profiles[id(cfg)] = {
                "chunk_chars": getattr(cfg, "edge_chunk_chars", None),
                "max_segment_seconds": getattr(cfg, "edge_max_segment_seconds", None),
                "enable_parallel": getattr(cfg, "edge_enable_parallel", True),
            }
        state["safe_profile"] = {
            "chunk_chars": chunk_chars,
            "max_segment_seconds": max_segment,
            "timeout_max": timeout_max,
            "parallel_cap": state["parallel_cap"],
        }

        for cfg in state.get("configs") or []:
            if (cfg.engine or "").lower() != "edge":
                continue
            cfg.edge_chunk_chars = min(cfg.edge_chunk_chars or chunk_chars, chunk_chars)
            cfg.edge_max_segment_seconds = min(
                cfg.edge_max_segment_seconds or max_segment,
                max_segment,
            )
            cfg.edge_enable_parallel = False

        if engine_obj is not None:
            if hasattr(engine_obj, "apply_speed_profile"):
                with contextlib.suppress(Exception):
                    engine_obj.apply_speed_profile(
                        chunk_char_limit=chunk_chars,
                        max_segment_seconds=max_segment,
                        words_per_minute=160,
                    )
            if hasattr(engine_obj, "_enable_parallel"):
                with contextlib.suppress(Exception):
                    setattr(engine_obj, "_enable_parallel", False)
                    setattr(engine_obj, "_parallel_slots", 1)

        state_current = self._parallel_state or {}
        current = max(1, int(state_current.get("current") or 1))
        ceiling = max(1, int(state_current.get("ceiling") or current))
        if "pre_slow_parallel" not in state:
            state["pre_slow_parallel"] = current
        new_current = min(current, state["parallel_cap"])
        new_ceiling = min(ceiling, state["parallel_cap"])
        state_current["current"] = max(1, new_current)
        state_current["ceiling"] = max(1, new_ceiling)
        self._parallel_state = state_current
        if engine_pool is not None:
            engine_pool.update_parallel_slots(state_current["current"])

        if announce:
            print(
                "🧯 Edge safe mode: "
                f"{reason} → chunk={chunk_chars} seg={int(max_segment)}s parallel={state_current['current']}"
            )
        return announce

    def _restore_edge_fast_mode(
        self,
        reason: str,
        *,
        engine_pool: Optional[JobEnginePool] = None,
        engine_obj: Optional[object] = None,
    ) -> bool:
        """Restore Edge settings back to the fast profile after recovery."""
        state = self._edge_auto_state or {}
        if not state.get("slow_mode"):
            return False

        state["slow_mode"] = False
        state["slow_mode_reason"] = None
        state["recovery_streak"] = 0
        fast_profiles = state.get("fast_profiles") or {}
        restored = False
        for cfg in state.get("configs") or []:
            if (cfg.engine or "").lower() != "edge":
                continue
            snapshot = fast_profiles.get(id(cfg))
            if not snapshot:
                continue
            restored = True
            if snapshot.get("chunk_chars") is not None:
                cfg.edge_chunk_chars = snapshot["chunk_chars"]
            if snapshot.get("max_segment_seconds") is not None:
                cfg.edge_max_segment_seconds = snapshot["max_segment_seconds"]
            if snapshot.get("enable_parallel") is not None:
                cfg.edge_enable_parallel = snapshot["enable_parallel"]

        fast_cap = int(state.get("fast_parallel_cap") or state.get("parallel_cap") or 1)
        state["parallel_cap"] = max(1, fast_cap)
        state_current = self._parallel_state or {}
        target_parallel = state.pop("pre_slow_parallel", None)
        if target_parallel is None:
            target_parallel = state_current.get("current") or fast_cap
        target_parallel = max(1, min(int(target_parallel), state["parallel_cap"]))
        state_current["ceiling"] = state["parallel_cap"]
        state_current["current"] = target_parallel
        self._parallel_state = state_current
        if engine_pool is not None:
            engine_pool.update_parallel_slots(target_parallel)

        if engine_obj is not None:
            with contextlib.suppress(Exception):
                if hasattr(engine_obj, "apply_speed_profile"):
                    restore_cfg = None
                    for cfg in state.get("configs") or []:
                        if (cfg.engine or "").lower() == "edge":
                            restore_cfg = cfg
                            break
                    chunk_chars = None
                    segment_seconds = None
                    if restore_cfg:
                        chunk_chars = getattr(restore_cfg, "edge_chunk_chars", None)
                        segment_seconds = getattr(restore_cfg, "edge_max_segment_seconds", None)
                    kwargs = {}
                    if chunk_chars:
                        kwargs["chunk_char_limit"] = chunk_chars
                    if segment_seconds:
                        kwargs["max_segment_seconds"] = segment_seconds
                    if kwargs:
                        engine_obj.apply_speed_profile(**kwargs)
                if hasattr(engine_obj, "_enable_parallel"):
                    setattr(engine_obj, "_enable_parallel", True)
                    if hasattr(engine_obj, "_parallel_slots"):
                        setattr(engine_obj, "_parallel_slots", target_parallel)

        self._edge_auto_state = state
        if restored and self.verbose:
            print(f"🚀 Edge safe mode disabled: {reason}")
        return restored

    def _maybe_exit_edge_slow_mode(
        self,
        *,
        engine_label: str,
        chapter_chars: int,
        elapsed: float,
        engine_pool: Optional[JobEnginePool] = None,
        engine_obj: Optional[object] = None,
    ) -> None:
        """Check if slow-mode constraints can be lifted after a fast chapter."""
        if (engine_label or "").lower() != "edge":
            return
        state = self._edge_auto_state or {}
        if not state.get("slow_mode"):
            return
        if chapter_chars <= 0 or elapsed <= 0:
            return

        throughput = chapter_chars / max(elapsed, 0.001)
        min_cps = float(state.get("min_chars_per_second") or EDGE_MIN_CHARS_PER_SECOND)
        recovery_threshold = max(min_cps * 1.25, min_cps + 30.0)
        reason = (state.get("slow_mode_reason") or "").lower()
        required_hits = 3
        if "chapter" in reason or "capitulo" in reason or "chapter" in reason:
            required_hits = 1
        elif "retry" in reason or "valid" in reason:
            required_hits = 2

        state["recovery_streak"] = int(state.get("recovery_streak") or 0)
        if throughput >= recovery_threshold:
            state["recovery_streak"] += 1
        else:
            state["recovery_streak"] = 0

        if state["recovery_streak"] >= required_hits:
            restored = self._restore_edge_fast_mode(
                f"speed recovered (~{int(throughput)} chars/s)",
                engine_pool=engine_pool,
                engine_obj=engine_obj,
            )
            if restored:
                state["recovery_streak"] = 0
        self._edge_auto_state = state

    @staticmethod
    def _should_force_edge_rescue(
        failures: Dict[str, str],
        *,
        edge_available: bool,
    ) -> bool:
        """Detect whether we should reprocess failed chapters with safer Edge settings."""
        if not edge_available or not failures:
            return False
        for message in failures.values():
            if not message:
                return True
            lower = message.lower()
            if any(
                keyword in lower
                for keyword in (
                    "timeout",
                    "time-out",
                    "rate limit",
                    "rate_limit",
                    "too many requests",
                    "403",
                    "no audio",
                    "noaudio",
                    "truncated",
                    "truncation",
                    "file missing",
                    "file invalid",
                    "edge",
                )
            ):
                return True
        return False

    def _apply_edge_rescue_profile(
        self,
        *,
        engine_pool: JobEnginePool,
        edge_configs: List[ConversionConfig],
        reason: str,
        aggressive: bool = False,
    ) -> Dict[str, float]:
        """
        Clamp Edge settings aggressively for retries to avoid stalls.

        Returns a profile dict so the caller can mirror values into ad-hoc configs.
        """
        chunk_chars = 3200 if not aggressive else 2400
        max_segment = 42.0 if not aggressive else 36.0
        offline_chars = 8000 if not aggressive else 6000
        offline_seconds = 300.0 if not aggressive else 220.0

        for cfg in edge_configs or []:
            if (cfg.engine or "").lower() != "edge":
                continue
            cfg.edge_chunk_chars = min(cfg.edge_chunk_chars or chunk_chars, chunk_chars)
            cfg.edge_max_segment_seconds = min(
                float(getattr(cfg, "edge_max_segment_seconds", 0) or max_segment),
                max_segment,
            )
            cfg.edge_enable_parallel = False
            cfg.edge_max_concurrency = 1
            cfg.edge_auto_offline_chars = min(
                getattr(cfg, "edge_auto_offline_chars", 0) or offline_chars,
                offline_chars,
            )
            cfg.edge_auto_offline_seconds = min(
                getattr(cfg, "edge_auto_offline_seconds", 0) or offline_seconds,
                offline_seconds,
            )

        state = self._parallel_state or {}
        state["current"] = 1
        state["ceiling"] = max(1, min(int(state.get("ceiling") or 1), 1))
        self._parallel_state = state
        engine_pool.update_parallel_slots(1)
        edge_state = self._edge_auto_state or {}
        edge_state["slow_mode"] = True
        self._edge_auto_state = edge_state

        profile_label = "safe mode" if not aggressive else "aggressive safe mode"
        print(
            f"🛟 Edge retry ({profile_label}): {reason} → "
            f"chunk={chunk_chars} seg={int(max_segment)}s offline>={offline_chars} chars"
        )
        return {
            "chunk_chars": chunk_chars,
            "max_segment": max_segment,
            "offline_chars": offline_chars,
            "offline_seconds": offline_seconds,
        }
