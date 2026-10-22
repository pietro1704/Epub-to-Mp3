# -*- coding: utf-8 -*-
"""Chapter synthesis budget."""

from __future__ import annotations


async def _chapter_synthesis_budget(self, _state):
    from . import converter as _runtime
    if (
        _state.edge_auto_enabled
        and _state.edge_state.get("slow_mode")
        and _state.current_engine_label == "edge"
    ):
        _state.safe_timeout = (_state.edge_state.get("safe_profile") or {}).get("timeout_max")
        if _state.safe_timeout:
            # Don't let safe_timeout reduce below size-based max_timeout
            _state.timeout_seconds = min(
                _state.timeout_seconds, max(int(_state.safe_timeout), int(_state.max_timeout))
            )
    # Aggressive local strategy for large chapters on Piper.
    if _state.current_engine_label == "piper" and _state.chapter_chars >= 15000:
        _state.cpu_physical = max(
            1,
            int(
                getattr(getattr(self, "hardware_profile", None), "cpu_physical", 2)
                or 2
            ),
        )
        _state.ram_total = float(
            getattr(getattr(self, "hardware_profile", None), "ram_total_gb", 0.0)
            or 0.0
        )
        if _state.chapter_chars >= 200000:
            _state.target_chunk = 1400
        elif _state.chapter_chars >= 100000:
            _state.target_chunk = 1800
        elif _state.chapter_chars >= 25000:
            _state.target_chunk = 2200
        else:
            _state.target_chunk = 2400
        _state.target_workers = min(4, _state.cpu_physical)
        if 0 < _state.ram_total < 8:
            _state.target_workers = min(_state.target_workers, 2)
        _state.target_workers = max(1, _state.target_workers)
        # Progressive safer tuning across retries (including deferred-safe pass)
        _state.retry_tier = max(0, int(_state.chapter_attempt) - 1)
        if _state.deferred_safe_pass:
            _state.retry_tier = max(_state.retry_tier, 3)
        if _state.retry_tier > 0:
            # Keep Piper fallback retries conservative but avoid collapsing
            # to single-worker mode, which can make very large chapters
            # impractically slow on CPU-only environments.
            _state.capped_tier = min(_state.retry_tier, 2)
            _state.target_chunk = max(1200, int(_state.target_chunk * (0.86**_state.capped_tier)))
            _state.target_workers = max(2, min(_state.target_workers, 4 - _state.capped_tier))
        _runtime.os.environ["PIPER_CHUNK_CHARS"] = str(_state.target_chunk)
        _runtime.os.environ["PIPER_MAX_PROCS"] = str(_state.target_workers)
        with _runtime.contextlib.suppress(Exception):
            setattr(_state.tts_engine, "_chunk_char_limit", _state.target_chunk)
        with _runtime.contextlib.suppress(Exception):
            setattr(_state.tts_engine, "_semaphore", _runtime.asyncio.Semaphore(_state.target_workers))
        _state.piper_min_timeout = float(
            _runtime.os.getenv("PIPER_LARGE_TIMEOUT_MIN", "900") or "900"
        )
        if _state.chapter_chars >= 200000:
            _state.piper_timeout_cap = float(
                _runtime.os.getenv("PIPER_LARGE_TIMEOUT_MAX_200K", "3600") or "3600"
            )
        elif _state.chapter_chars >= 100000:
            _state.piper_timeout_cap = float(
                _runtime.os.getenv("PIPER_LARGE_TIMEOUT_MAX_100K", "2400") or "2400"
            )
        elif _state.chapter_chars >= 50000:
            _state.piper_timeout_cap = float(
                _runtime.os.getenv("PIPER_LARGE_TIMEOUT_MAX_50K", "1800") or "1800"
            )
        else:
            _state.piper_timeout_cap = float(
                _runtime.os.getenv("PIPER_LARGE_TIMEOUT_MAX", "900") or "900"
            )
        if _state.deferred_safe_pass:
            _state.piper_timeout_cap = max(_state.piper_timeout_cap, 1800.0)
        _state.timeout_seconds = min(
            max(_state.timeout_seconds, _state.piper_min_timeout), _state.piper_timeout_cap
        )
        if self.verbose:
            print(
                f"⚡ Piper large-chapter mode: chunks={_state.target_chunk}, "
                f"workers={_state.target_workers}, timeout={int(_state.timeout_seconds)}s"
            )
    _state.timeout_seconds = int(_state.timeout_seconds)
    _state.stall_seconds = float(_runtime.os.getenv("CHAPTER_STALL_SECONDS", "120") or "120")
    if _state.stall_seconds < 0:
        _state.stall_seconds = 0.0
    # Avoid false "stuck" detection on large local chapters (Piper):
    # synthesis can take >45-60s before first progress callback.
    if _state.current_engine_label in {"piper"} and _state.chapter_chars >= 50000:
        _state.local_floor = float(
            _runtime.os.getenv("LOCAL_ENGINE_STALL_MIN_SECONDS", "600") or "600"
        )
        _state.proportional = max(
            _state.local_floor,
            min(float(_state.timeout_seconds) * 0.40, float(_state.timeout_seconds) * 0.85),
        )
        _state.stall_seconds = max(_state.stall_seconds, _state.proportional)
        if self.verbose:
            print(
                f"🛡️ Local engine stall guard: stall timeout={int(_state.stall_seconds)}s"
            )

    if self.verbose:
        print(
            f"🎤 [{_state.chapter_num}/{len(_state.chapters_list)}] {_state.chapter.name}: Starting TTS synthesis"
        )
        print(f"   📝 Text: {_state.chapter_chars} chars (timeout: {_state.timeout_seconds}s)")

    self.progress.tick(
        f"🎤 Synthesizing {_state.chapter_chars} chars (timeout: {_state.timeout_seconds}s)..."
    )

    # Heartbeat to show progress (optimized: 3s instead of 1s)
    _state.heartbeat_active = True
    _state.start_synthesis = _runtime.time.time()

    async def synthesis_heartbeat():
        spinner_frames = ["⚙️", "🔧"]
        frame_idx = 0
        while _state.heartbeat_active:
            await _runtime.asyncio.sleep(5)  # Update every 5 seconds (reduces overhead)
            if not _state.heartbeat_active:
                break
            elapsed = int(_runtime.time.time() - _state.start_synthesis)
            frame = spinner_frames[frame_idx % len(spinner_frames)]
            self.progress.tick(
                f"{frame} Synthesizing... {elapsed}s/{_state.timeout_seconds}s ({_state.chapter_chars} chars)"
            )
            self._mark_health_activity(_state.chapter_num, "heartbeat")
            frame_idx += 1
    _state.synthesis_heartbeat = synthesis_heartbeat

    _state.heartbeat_task = _runtime.asyncio.create_task(_state.synthesis_heartbeat())
