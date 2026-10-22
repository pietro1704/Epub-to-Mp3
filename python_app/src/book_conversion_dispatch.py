# -*- coding: utf-8 -*-
"""Book conversion dispatch."""

from __future__ import annotations

from typing import Dict, List, Optional, Set

from .config import ConversionConfig


async def _book_conversion_dispatch(self, _state):
    from . import converter as _runtime
    _state.edge_auto_override = getattr(_state.config, "edge_auto_tune", None)
    _state.edge_auto_enabled = (
        _runtime.EDGE_AUTO_TUNE if _state.edge_auto_override is None else bool(_state.edge_auto_override)
    ) and _state.has_edge_engine
    _state.parallel_slots_cap: Optional[int] = None
    if _state.edge_auto_enabled:
        _state.parallel_slots_cap = _runtime.EDGE_AUTO_PARALLEL_CAPS.get(
            _state.edge_network_tier, _runtime.EDGE_SAFE_CHAPTER_PARALLEL
        )
    _state.edge_configs: List[ConversionConfig] = []
    _state.edge_seen: Set[int] = set()
    for _state.cfg in (
        _state.config,
        _state.auto_engine_pool.get("edge")[0]
        if _state.is_auto_engine and _state.auto_engine_pool and "edge" in _state.auto_engine_pool
        else None,
    ):
        if _state.cfg and (_state.cfg.engine or "").lower() == "edge" and id(_state.cfg) not in _state.edge_seen:
            _state.edge_configs.append(_state.cfg)
            _state.edge_seen.add(id(_state.cfg))
    _state.config_snapshots: Dict[int, Dict[str, object]] = {}
    for _state.cfg in _state.edge_configs:
        _state.config_snapshots[id(_state.cfg)] = {
            "chunk_chars": getattr(_state.cfg, "edge_chunk_chars", None),
            "max_segment_seconds": getattr(_state.cfg, "edge_max_segment_seconds", None),
            "enable_parallel": getattr(_state.cfg, "edge_enable_parallel", True),
        }
    self._apply_edge_rate_caps(_state.edge_configs)
    if _state.has_edge_engine and _state.edge_network_tier in {"slow", "medium"} and not _state.edge_stable_mode:
        for _state.cfg in _state.edge_configs:
            if (_state.cfg.engine or "").lower() != "edge":
                continue
            if _state.edge_network_tier == "slow":
                if (_state.cfg.edge_chunk_chars or 0) > 6000:
                    _state.cfg.edge_chunk_chars = 6000
                if (_state.cfg.edge_max_segment_seconds or 0) > 60:
                    _state.cfg.edge_max_segment_seconds = 60
                _state.cfg.edge_enable_parallel = False
            else:
                if (_state.cfg.edge_chunk_chars or 0) > 8000:
                    _state.cfg.edge_chunk_chars = 8000
                if (_state.cfg.edge_max_segment_seconds or 0) > 75:
                    _state.cfg.edge_max_segment_seconds = 75
        if _state.edge_network_tier == "slow" and _state.chapter_parallel_count > 1:
            _state.chapter_parallel_count = 1
            self._reset_parallel_state(_state.chapter_parallel_count)
        elif _state.edge_network_tier == "medium" and _state.chapter_parallel_count > 2:
            _state.chapter_parallel_count = 2
            self._reset_parallel_state(_state.chapter_parallel_count)
        print("🌧️ Edge: unstable network detected → starting with conservative profile")
    self._edge_auto_state = {
        "enabled": _state.edge_auto_enabled,
        "network_tier": _state.edge_network_tier,
        "parallel_cap": _state.parallel_slots_cap,
        "fast_parallel_cap": _state.parallel_slots_cap or _state.chapter_parallel_count,
        "slow_mode": False,
        "safe_profile": {
            "chunk_chars": _runtime.EDGE_SAFE_CHUNK_CHARS,
            "max_segment_seconds": _runtime.EDGE_SAFE_MAX_SEGMENT_SECONDS,
            "timeout_max": _runtime.EDGE_SAFE_TIMEOUT_MAX,
            "parallel_cap": _runtime.EDGE_SAFE_CHAPTER_PARALLEL,
        },
        "min_chars_per_second": _runtime.EDGE_MIN_CHARS_PER_SECOND,
        "slow_ratio_threshold": _runtime.EDGE_SLOW_RATIO_THRESHOLD,
        "configs": _state.edge_configs,
        "fast_profiles": _state.config_snapshots,
        "recovery_streak": 0,
    }
    if _state.edge_stable_mode and _state.has_edge_engine:
        _state.safe_profile = self._edge_auto_state.get("safe_profile") or {}
        _state.safe_profile["chunk_chars"] = 4000
        _state.safe_profile["max_segment_seconds"] = 120
        _state.safe_profile["timeout_max"] = max(float(_state.safe_profile.get("timeout_max") or 0), 1200.0)
        _state.safe_profile["parallel_cap"] = 1
        self._edge_auto_state["safe_profile"] = _state.safe_profile
        self._edge_auto_state["parallel_cap"] = 1
    if _state.edge_auto_enabled and _state.parallel_slots_cap:
        if _state.chapter_parallel_count > _state.parallel_slots_cap:
            _state.chapter_parallel_count = _state.parallel_slots_cap
            self._reset_parallel_state(_state.chapter_parallel_count)
        print(
            f"🌐 Edge auto-adjustment: limit {_state.parallel_slots_cap} chapter(s) in parallel ({_state.edge_network_tier})"
        )

    if _state.chapter_parallel_count > 1:
        print(
            f"🚀 Parallel mode (automatic): up to {_state.chapter_parallel_count} concurrent chapters"
        )
    else:
        print("🔄 Sequential mode (automatic): processing chapters one at a time")

    _state.edge_cap = 0
    try:
        _state.edge_cap = int(_runtime.os.getenv("EDGE_MAX_CONCURRENCY", "") or "0")
    except ValueError:
        _state.edge_cap = 0
    _state.parallel_slots = max(1, int(self._parallel_state.get("current") or _state.chapter_parallel_count))
    self._record_effective_runtime_profile(
        config=_state.config,
        edge_engine=_state.engine_seeds.get("edge"),
        chapter_parallel_count=_state.chapter_parallel_count,
        network_tier=_state.edge_network_tier,
        edge_cap=_state.edge_cap,
        output_dir=_state.temp_dir,
    )
    _state.engine_pool = _runtime.JobEnginePool(
        create_engine=self.tts_factory.create_engine,
        parallel_slots=_state.parallel_slots,
        edge_cap=_state.edge_cap,
        hardware_profile=self.hardware_profile,
        stats_provider=self._resource_snapshot,
    )
    if _state.is_auto_engine:
        for _state.name, (_state.pool_config, _state.engine_obj) in _state.auto_engine_pool.items():
            _state.engine_pool.register_engine(_state.name, _state.pool_config, _state.engine_obj)
    else:
        _state.engine_name = (_state.config.engine or "").lower()
        _state.engine_pool.register_engine(_state.engine_name, _state.config, _state.engine_seeds.get(_state.engine_name))

    async def _synthesize_safe(engine_obj, text, output_path, **kwargs):
        """Call engine.synthesize_async filtering unsupported kwargs for dummy engines."""
        try:
            sig = _runtime.inspect.signature(engine_obj.synthesize_async)
            allowed = {k: v for k, v in kwargs.items() if k in sig.parameters}
        except Exception:
            allowed = kwargs
        return await engine_obj.synthesize_async(text, output_path, **allowed)
    _state._synthesize_safe = _synthesize_safe

    # Choose parallel or sequential based on hardware detection
    if _state.chapter_parallel_count > 1:
        _state.result = await self._convert_chapters_parallel(
            _state.pending_chapters,
            _state.engine_pool,
            _state.temp_dir,
            _state.config,
            max_concurrent_chapters=_state.chapter_parallel_count,
            skip_preprocessing=True,  # Already done above
            is_auto_engine=_state.is_auto_engine,
            auto_engine_pool=_state.auto_engine_pool,
            book_title=_state.book_title,
            book_author=_state.book_author,
            cover_art=_state.cover_art,
        )
    else:
        _state.result = await self._convert_chapters_sequential(
            _state.pending_chapters,
            _state.engine_pool,
            _state.temp_dir,
            _state.config,
            skip_preprocessing=True,  # Already done above
            is_auto_engine=_state.is_auto_engine,
            auto_engine_pool=_state.auto_engine_pool,
            book_title=_state.book_title,
            book_author=_state.book_author,
            cover_art=_state.cover_art,
        )
    _state.total_output_files = list(_state.cached_paths) + list(_state.result.output_files)
    _state.raw_failures = self._build_error_map(_state.result.errors)
    _state.pending_failures, _state.unresolved_failures = self._normalise_failure_keys(
        _state.raw_failures, _state.chapter_lookup
    )
    _state.unresolved_pool: Dict[str, str] = dict(_state.unresolved_failures)
    _state.attempts_used: Dict[str, int] = {label: 1 for label in _state.pending_failures}

    for _state.unresolved in _state.unresolved_failures:
        print(f"⚠️ Could not correlate failed chapter: {_state.unresolved}")

    _state.max_retry_rounds = 2
    _state.extra_retry_value = None
    if getattr(_state.config, "extra", None):
        _state.extra_retry_value = _state.config.extra.get("max_auto_retries") or _state.config.extra.get(
            "max_retries"
        )
    if _state.extra_retry_value is None:
        _state.extra_retry_value = getattr(_state.config, "max_auto_retries", None)
    try:
        if _state.extra_retry_value is not None:
            _state.max_retry_rounds = max(0, int(_state.extra_retry_value))
    except (ValueError, TypeError):
        pass
    if _state.extra_retry_value is None and (_state.config.engine or "").lower() == "edge":
        _state.max_retry_rounds = max(_state.max_retry_rounds, 6)
    if not _state.pending_failures and _state.result.converted_chapters < _state.pending_total:
        _state.fallback_detected = self._detect_failed_chapters_by_output(_state.pending_chapters, _state.temp_dir)
        if _state.fallback_detected:
            for _state.label in _state.fallback_detected:
                _state.attempts_used.setdefault(_state.label, 1)
            _state.pending_failures.update(_state.fallback_detected)
            print(f"\n⚠️ Chapters without valid audio detected: {len(_state.fallback_detected)}")
            if self.verbose:
                print("   → " + ", ".join(sorted(_state.fallback_detected.keys())))

    if _state.pending_failures:
        _state.failed_labels = ", ".join(sorted(_state.pending_failures.keys()))
        print(f"\n⚠️ Failed chapters detected: {len(_state.pending_failures)}")
        if self.verbose:
            print(f"   → {_state.failed_labels}")

    _state.edge_available = _state.engine_pool.has_engine("edge")
    _state.edge_rescue_applied = False
    _state.edge_rescue_aggressive = False
    _state.forced_offline_once = False
    _state.manual_retry_requested = False
    if getattr(_state.config, "extra", None):
        _state.manual_flag = _state.config.extra.get("manual_retry_failed")
        _state.manual_retry_requested = str(_state.manual_flag).lower() in {"1", "true", "yes", "on"}

    _state.retry_round = 1
