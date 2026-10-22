# -*- coding: utf-8 -*-
"""Sequential session preparation."""

from __future__ import annotations

from typing import Dict, List, Optional, Set

from .config import ConversionConfig
from .conversion_control import ConversionControl as _ConversionControl


async def _sequential_session_preparation(self, _state):
    from . import converter as _runtime
    """Convert chapters sequentially, without parallelism."""
    _state.chapters_list = list(_state.chapters)
    _state.selected_indices_raw = (_state.config.extra.get("selected_indices") or "").strip()
    if _state.selected_indices_raw:
        _state.allowed = {item.strip() for item in _state.selected_indices_raw.split(",") if item.strip()}
        if _state.allowed:
            _state.chapters_list = [ch for ch in _state.chapters_list if str(ch.index) in _state.allowed]
    if not _state.chapters_list:
        return _ConversionControl("return", _runtime.ConversionResult(True, 0, 0, [], []))
    _state.original_total = len(_state.chapters_list)
    _state.edge_stable_mode = False
    if getattr(_state.config, "extra", None):
        _state.stable_raw = _state.config.extra.get("edge_stable_mode")
        if _state.stable_raw is not None:
            _state.edge_stable_mode = str(_state.stable_raw).lower() in {
                "1",
                "true",
                "yes",
                "on",
            }
    if (
        not _state.edge_stable_mode
        and _runtime.EDGE_AUTO_STABLE
        and (_state.config.engine or "").lower() == "edge"
        and _runtime.os.getenv("EDGE_NETWORK_TIER", "").strip().lower() == "slow"
    ):
        _state.edge_stable_mode = True

    # Preflight: detect DNS issues, but do not bypass Edge entirely.
    # Product requirement: always attempt Edge at least once before offline fallback.
    if (_state.config.engine or "").lower() == "edge":
        try:
            _runtime.socket.getaddrinfo("speech.platform.bing.com", 443, proto=_runtime.socket.IPPROTO_TCP)
        except Exception:
            if self.verbose:
                print(
                    "🛟 Edge DNS unavailable in preflight; still trying Edge 1x before offline fallback"
                )

    # Compat: accept a direct engine instead of a pool
    if hasattr(_state.engine_pool, "synthesize_async") and not hasattr(_state.engine_pool, "acquire"):
        _state.engine_instance = _state.engine_pool

        class _SingleEnginePool:
            def __init__(self, engine_obj):
                self.engine_obj = engine_obj

            async def acquire(self, *_args, **_kwargs):
                return _state.config, self.engine_obj

            def release(self, *_args, **_kwargs):
                return None

            def register_engine(self, *_args, **_kwargs):
                """No-op for compatibility with test mocks"""
                return None
        _state._SingleEnginePool = _SingleEnginePool

        _state.engine_pool = _state._SingleEnginePool(_state.engine_instance)

    async def _synthesize_safe(engine_obj, text, output_path, **kwargs):
        """Call engine.synthesize_async filtering unsupported kwargs for dummy engines."""
        try:
            sig = _runtime.inspect.signature(engine_obj.synthesize_async)
            allowed = {k: v for k, v in kwargs.items() if k in sig.parameters}
        except Exception:
            allowed = kwargs
        callback = allowed.get("chunk_callback")
        if callback is None:
            return await engine_obj.synthesize_async(text, output_path, **allowed)

        def invoke(observed_callback):
            return engine_obj.synthesize_async(
                text, output_path, **{**allowed, "chunk_callback": observed_callback}
            )

        return await _runtime.observe_synthesis(invoke, callback)
    _state._synthesize_safe = _synthesize_safe

    # If preprocessing already done by caller, skip duplicate work
    if not _state.skip_preprocessing:
        # Auto-skip credits/very short chapters if not cached
        _state.chapters_list = self._filter_chapters_auto(_state.chapters_list, _state.output_dir, _state.config)

        print(f"🔄 Sequential mode: processing {len(_state.chapters_list)} chapters")

        # **NEW**: Check for cache invalidation BEFORE generating text files
        # If MP3 exists but pre-tts.txt doesn't, delete MP3 (cache invalidated)
        self._validate_and_clean_cache(_state.chapters_list, _state.output_dir, _state.config)

        _state.generated_text = False
        _state.cleanup_existing = bool(
            getattr(_state.config, "force_reprocess", False) or getattr(_state.config, "clear_cache", False)
        )
        if getattr(_state.config, "auto_validate_output", True):
            self._generate_all_text_files(
                _state.chapters_list, _state.output_dir, _state.config, cleanup_existing=_state.cleanup_existing
            )
            _state.generated_text = True

        # **FAST-PATH**: Try cache reuse before generating text (index-only allowed)
        _state.cached_audio, _state.pending_chapters = self._split_cached_chapters(
            _state.chapters_list, _state.output_dir, _state.config, allow_index_only=True
        )

        # **NEW**: Generate ALL text files BEFORE starting conversion (if needed)
        if _state.pending_chapters and not _state.generated_text:
            self._generate_all_text_files(
                _state.chapters_list, _state.output_dir, _state.config, cleanup_existing=_state.cleanup_existing
            )
            # Retry cache after having pre-tts hashes
            _state.cached_audio, _state.pending_chapters = self._split_cached_chapters(
                _state.chapters_list, _state.output_dir, _state.config, allow_index_only=False
            )

        # **FAST-PATH**: If all MP3s already exist, skip synthesis and return.
        if _state.cached_audio and not _state.pending_chapters:
            print(
                f"♻️ All {len(_state.chapters_list)} chapter(s) already cached (MP3) — skipping synthesis"
            )
            for _state.chap in _state.chapters_list:
                self.progress.tick("✅ Complete (cache)") if hasattr(self, "progress") else None
            return _ConversionControl("return", _runtime.ConversionResult(
                success=True,
                total_chapters=_state.original_total,
                converted_chapters=_state.original_total,
                output_files=_state.cached_audio,
                errors=[],
            ))
        if _state.cached_audio and _state.pending_chapters:
            print(
                f"♻️ Cache detected: {len(_state.cached_audio)} chapter(s) ready; "
                f"converting {len(_state.pending_chapters)} remaining"
            )
        self._assign_progress_indices(_state.pending_chapters)
        _state.chapters_list = _state.pending_chapters
    else:
        # Preprocessing done by caller, just print status
        print(f"🔄 Sequential mode: processing {len(_state.chapters_list)} chapters")
        _state.cached_audio = []  # No cached files when preprocessing done by caller

    _state.converted_files: List[_runtime.Path] = list(_state.cached_audio)
    _state.errors: List[str] = []
    _state.cooldown_pattern = _runtime.re.compile(r"cooldown\\s+(\\d+)s", _runtime.re.IGNORECASE)

    def _edge_error_reason(last_error: Optional[str]) -> str:
        reason = self._classify_failure_reason(last_error)
        if reason == "throttle":
            return "rate_limit"
        if reason == "transient":
            return "timeout"
        return reason
    _state._edge_error_reason = _edge_error_reason

    _state.edge_unavailable_hits = 0
    _state.auto_engine_pool = _state.auto_engine_pool or {}
    _state.unavailable_engines: Set[str] = set()
    _state.edge_globally_blocked = False
    _state.edge_blocked_chapters_global: Set[str] = set()
    if getattr(_state.config, "extra", None):
        _state.raw_blocked = _state.config.extra.get("edge_blocked_chapters") or []
        if isinstance(_state.raw_blocked, (list, tuple, set)):
            _state.edge_blocked_chapters_global = {
                str(item).strip() for item in _state.raw_blocked if str(item).strip()
            }
        else:
            _state.edge_blocked_chapters_global = {
                part.strip() for part in str(_state.raw_blocked).split(",") if part.strip()
            }
    _state.edge_state = self._edge_auto_state or {}
    _state.edge_auto_enabled = bool(_state.edge_state.get("enabled"))
    _state.edge_force_offline = bool(_state.edge_state.get("force_offline_after_trunc"))
    _state.edge_circuit = self._edge_circuit_state
    _state.edge_circuit["open"] = False
    _state.edge_circuit["failures"] = 0
    _state.edge_circuit["opened_at"] = 0.0
    _state.edge_circuit["last_reason"] = ""

    def _edge_circuit_open() -> bool:
        if not bool(_state.edge_circuit.get("open")):
            return False
        opened_at = float(_state.edge_circuit.get("opened_at") or 0.0)
        cooldown = float(_state.edge_circuit.get("cooldown_seconds") or 900.0)
        if opened_at > 0 and (_runtime.time.time() - opened_at) >= cooldown:
            _state.edge_circuit["open"] = False
            _state.edge_circuit["failures"] = 0
            _state.edge_circuit["opened_at"] = 0.0
            _state.edge_circuit["last_reason"] = ""
            if self.verbose:
                print("✅ Edge circuit breaker reset after cooldown")
            return False
        return True
    _state._edge_circuit_open = _edge_circuit_open

    def _trip_edge_circuit(reason: str) -> None:
        failures = int(_state.edge_circuit.get("failures", 0) or 0) + 1
        _state.edge_circuit["failures"] = failures
        _state.edge_circuit["last_reason"] = reason
        threshold = int(_state.edge_circuit.get("threshold", 2) or 2)
        if failures >= threshold:
            _state.edge_circuit["open"] = True
            _state.edge_circuit["opened_at"] = _runtime.time.time()
            _state.unavailable_engines.add("edge")
            if self.verbose:
                print(f"🧯 Edge circuit breaker OPEN ({reason})")
    _state._trip_edge_circuit = _trip_edge_circuit

    def _reset_edge_circuit() -> None:
        _state.edge_circuit["open"] = False
        _state.edge_circuit["failures"] = 0
        _state.edge_circuit["opened_at"] = 0.0
        _state.edge_circuit["last_reason"] = ""
    _state._reset_edge_circuit = _reset_edge_circuit

    def _maybe_apply_edge_slow_mode(reason: str, engine_obj: Optional[object] = None) -> None:
        if _state.edge_auto_enabled:
            self._apply_edge_slow_mode(reason, engine_pool=_state.engine_pool, engine_obj=engine_obj)
    _state._maybe_apply_edge_slow_mode = _maybe_apply_edge_slow_mode

    def available_auto_pool() -> Dict[str, tuple[ConversionConfig, object]]:
        if not _state.auto_engine_pool:
            return {}
        circuit_open = _state._edge_circuit_open()
        return {
            name: entry
            for name, entry in _state.auto_engine_pool.items()
            if name not in _state.unavailable_engines and not (circuit_open and name == "edge")
        }
    _state.available_auto_pool = available_auto_pool

    def can_use_piper() -> bool:
        """Check if Piper is usable in this environment."""
        if not _runtime._has_piper_support():
            return False
        # Check venv first (common locations)
        venv_locations = [
            _runtime.Path(".venv/bin/piper"),
            _runtime.Path("venv/bin/piper"),
            _runtime.Path(_runtime.sys.executable).parent / "piper",
        ]
        for piper_path in venv_locations:
            if piper_path.exists() and piper_path.is_file():
                return True
        # Fallback to system PATH
        return _runtime.shutil.which("piper") is not None
    _state.can_use_piper = can_use_piper

    def build_best_offline_engine(
        reason: Optional[str] = None,
        *,
        tracker: Optional[dict] = None,
        engine_ref: Optional[dict] = None,
    ) -> bool:
        return False
    _state.build_best_offline_engine = build_best_offline_engine

    if (_state.config.engine or "").lower() == "edge" and not _state.is_auto_engine:
        _state.edge_engine = None
        try:
            _state._, _state.edge_engine = await _state.engine_pool.acquire("edge")
            if _state.edge_engine and hasattr(_state.edge_engine, "_probe_edge_health"):
                _state.voice = getattr(_state.edge_engine, "voice", None)
                _state.healthy = await _state.edge_engine._probe_edge_health(_state.voice)  # type: ignore[attr-defined]
                if not _state.healthy and self.verbose:
                    print("   ⚠️ Edge pre-check failed; keeping selected engine")
        except Exception:
            pass
        finally:
            if _state.edge_engine is not None:
                _state.engine_pool.release("edge", _state.edge_engine)
