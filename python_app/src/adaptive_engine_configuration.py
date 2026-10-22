"""Persist adaptive engine parameters and resolve runtime pipeline configuration."""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import time
from pathlib import Path
from typing import Dict, Optional

from .config import ConversionConfig


class AdaptiveEngineConfiguration:
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
                "segment_duration_policy": dict(
                    self._segment_adaptive_state.get("segment_duration_policy", {}) or {}
                ),
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
                "segment_duration_policy",
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
        elif engine_name == "piper":
            params["piper_max_procs"] = int(
                getattr(cfg, "piper_max_procs", 0) or os.getenv("PIPER_MAX_PROCS", "2") or 2
            )
            params["piper_chunk_chars"] = int(
                getattr(cfg, "piper_chunk_chars", 0)
                or os.getenv("PIPER_CHUNK_CHARS", "3000")
                or 3000
            )
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
        from . import _edge_throttle_mixin as _runtime

        if config is None:
            return _runtime.STAGE_PIPELINE_ENABLED_DEFAULT
        raw = getattr(config, "extra", {}).get("stage_pipeline")
        if raw is None:
            return _runtime.STAGE_PIPELINE_ENABLED_DEFAULT
        return str(raw).strip().lower() in {"1", "true", "yes", "on"}

    @staticmethod
    def _stage_pipeline_depth(config: Optional[ConversionConfig]) -> int:
        """Depth of the prepare → synthesize stage pipeline queue.

        v0.3.28: decoupled from chapter parallelism. The prepare stage
        (text payload resolution from cache) is light, runs in a thread,
        and pre-populating it does not consume meaningful RAM. So we
        scale with available cores when there is no explicit override,
        instead of capping at the conservative default of 2 — that
        previous default left CPU idle whenever the auto-tuner shrunk
        chunks and the chapter parallelism cap kicked in.
        """
        from . import _edge_throttle_mixin as _runtime

        raw = None if config is None else getattr(config, "extra", {}).get("stage_pipeline_depth")
        if raw is None:
            try:
                cpu = max(1, (os.cpu_count() or 4))
            except Exception:
                cpu = 4
            # Default: max(STAGE_PIPELINE_DEPTH_DEFAULT, min(cpu, 8)).
            # Honors STAGE_PIPELINE_DEPTH env var if set, otherwise scales
            # to CPU but caps at 8 to avoid runaway prepare buffers on
            # high-core machines.
            return max(_runtime.STAGE_PIPELINE_DEPTH_DEFAULT, min(cpu, 8))
        try:
            return max(1, int(raw))
        except (TypeError, ValueError):
            return _runtime.STAGE_PIPELINE_DEPTH_DEFAULT

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
