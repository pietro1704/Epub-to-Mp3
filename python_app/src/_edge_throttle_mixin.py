"""Edge throttle, adaptive state, and resource budget mixin for AudioConverter."""

from __future__ import annotations

import contextlib
from typing import Dict, List, Optional


from ._env_utils import env_bool as _env_bool
from ._env_utils import env_float as _env_float
from ._env_utils import env_int as _env_int
from .adaptive_engine_configuration import AdaptiveEngineConfiguration
from .config import ConversionConfig
from .engine_resource_budget import EngineResourceBudget
from .segment_adaptive_tuning import SegmentAdaptiveTuning
from .engine_pool import JobEnginePool

# Mirror of the same constants defined in converter.py — evaluated from env vars
# so that runtime overrides (e.g. HF Spaces profile) are respected identically.
EDGE_MIN_CHARS_PER_SECOND = _env_float("EDGE_MIN_CHARS_PER_SECOND", 60.0)
EDGE_SAFE_CHUNK_CHARS = _env_int("EDGE_SAFE_CHUNK_CHARS", 10000)
EDGE_SAFE_MAX_SEGMENT_SECONDS = _env_float("EDGE_SAFE_MAX_SEGMENT_SECONDS", 300.0)
EDGE_SAFE_CHAPTER_PARALLEL = _env_int("EDGE_SAFE_CHAPTER_PARALLEL", 8)
EDGE_SAFE_TIMEOUT_MAX = _env_float("EDGE_SAFE_TIMEOUT_MAX", 3600.0)
STAGE_PIPELINE_ENABLED_DEFAULT = _env_bool("STAGE_PIPELINE_ENABLED", True)
STAGE_PIPELINE_DEPTH_DEFAULT = max(1, _env_int("STAGE_PIPELINE_DEPTH", 2))


class _EdgeThrottleMixin(AdaptiveEngineConfiguration, SegmentAdaptiveTuning, EngineResourceBudget):


    @staticmethod
    def _chapter_cap_from_edge_chunk() -> Optional[int]:
        """Derive a chapter-parallel ceiling from the live Edge chunk size.

        Tracks the global ``_edge_current_chunk_size`` mutated by
        ``EdgeTtsEngine._apply_tuning``. The mapping is deliberately coarse —
        the goal is to back off chapter concurrency when the per-segment tuner
        has reacted to throttling, not to micro-manage every adjustment.
        """
        try:
            from python_app.src.tts import edge_engine as _edge_mod  # local import avoids cycle
        except Exception:
            return None
        chunk = getattr(_edge_mod, "_edge_current_chunk_size", None)
        try:
            chunk_int = int(chunk) if chunk else 0
        except (TypeError, ValueError):
            return None
        if chunk_int <= 0:
            return None
        if chunk_int <= 4500:
            return 4
        if chunk_int <= 6500:
            return 8
        return None  # chunk healthy → no extra cap

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
