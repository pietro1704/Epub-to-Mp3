# -*- coding: utf-8 -*-
"""Sequential chapter pipeline."""

from __future__ import annotations

from pathlib import Path
from typing import Dict, Optional


from .chapter_iteration_preparation import _chapter_iteration_preparation
from .chapter_attempt_coordinator import _chapter_attempt_coordinator

async def _sequential_chapter_pipeline(self, _state):
    from . import converter as _runtime
    if _state.is_auto_engine:

        async def wait_edge_cooldown_if_needed(
            context: str,
            tracker: Optional[dict] = None,
            engine_ref: Optional[dict] = None,
        ) -> bool:
            return False
        _state.wait_edge_cooldown_if_needed = wait_edge_cooldown_if_needed
    else:

        async def wait_edge_cooldown_if_needed(
            context: str,
            tracker: Optional[dict] = None,
            engine_ref: Optional[dict] = None,
        ) -> bool:
            """
                Handle Edge outages without switching engines (manual mode).
                Wait briefly for cooldown before trying again.
                """
            if (_state.config.engine or "").lower() != "edge":
                return False
            engine_obj = engine_ref.get("object") if isinstance(engine_ref, dict) else None
            last_error = getattr(engine_obj, "last_error", None) if engine_obj else None
            if not last_error:
                return False

            reason = _state._edge_error_reason(last_error)
            if reason not in {
                "service_unavailable",
                "no_audio",
                "rate_limit",
                "timeout",
                "network",
            }:
                return False

            match = _state.cooldown_pattern.search(str(last_error))
            seconds = int(match.group(1)) if match else 0
            if seconds <= 0:
                seconds = 12
            if self.verbose:
                print(f"   ⚠️ Edge unavailable ({context}) - error: {last_error}")
            _state.edge_unavailable_hits += 1
            if _state.edge_unavailable_hits >= _runtime.EDGE_MONOLINGUAL_THRESHOLD:
                raise RuntimeError("edge_unavailable_threshold")
            _state._maybe_apply_edge_slow_mode(f"Edge unavailable ({reason})", engine_obj=engine_obj)

            max_wait = min(seconds, 25)
            if self.verbose:
                print(
                    f"   ⏳ No fallback available; waiting {max_wait}s before trying again..."
                )
            waited = 0
            while waited < max_wait:
                chunk = min(3, max_wait - waited)
                await _runtime.asyncio.sleep(chunk)
                waited += chunk
                self.progress.tick(f"⏳ Edge unavailable - waiting {max_wait - waited}s...")
            return True
        _state.wait_edge_cooldown_if_needed = wait_edge_cooldown_if_needed

    def _resolve_tts_output_path(
        final_mp3_path: Path, engine_name: Optional[str] = None
    ) -> tuple[Path, bool]:
        engine = (engine_name or _state.config.engine or "").lower()
        if engine in {"piper"}:
            return final_mp3_path.with_suffix(".wav"), True
        return final_mp3_path, False
    _state._resolve_tts_output_path = _resolve_tts_output_path

    class _RetryChapter(Exception):
        pass
    _state._RetryChapter = _RetryChapter

    async def _maybe_apply_edge_fallback() -> None:

        current_engine = (_state.config.engine or "").lower()
        if current_engine != "edge":
            return

        # TIER 2: Edge monolingual after MONOLINGUAL_THRESHOLD failures
        if (
            current_engine == "edge"
            and not _state.edge_switched_to_monolingual
            and _state.edge_consecutive_failures >= _runtime.EDGE_MONOLINGUAL_THRESHOLD
        ):
            from .config import VoiceConfigProvider

            voice_provider = VoiceConfigProvider()
            monolingual_voice = voice_provider.get_monolingual_voice(_state.config.primary_language)
            if monolingual_voice and monolingual_voice != _state.config.voice:
                print(f"\n🔄 Edge-TTS com {_state.edge_consecutive_failures} failures consecutive")
                print(f"   🔀 Switching to Edge monolingual: {_state.config.primary_language}")
                print(f"   🎤 New voice: {monolingual_voice}")
                _state.config = _runtime.replace(_state.config, voice=monolingual_voice)
                _state.engine_pool.register_engine("edge", _state.config)
                _state.edge_switched_to_monolingual = True
                _state.edge_consecutive_failures = 0
                return
            else:
                # No monolingual voice, skip to Piper
                _state.edge_switched_to_monolingual = True

        # TIER 3: Piper after PIPER_THRESHOLD failures (from monolingual Edge)
        if (
            _runtime._chain_tier_allowed("piper")
            and not _state.edge_switched_to_piper
            and _state.edge_consecutive_failures >= _runtime.EDGE_PIPER_THRESHOLD
            and _state.edge_switched_to_monolingual
        ):
            if _state.can_use_piper():
                piper_language = self._effective_primary_language(_state.config)
                print(f"\n🔄 Edge com {_state.edge_consecutive_failures} failures consecutive")
                print(f"   🛟 Switching to Piper (offline) for language: {piper_language}")
                from .config import VoiceConfigProvider

                voice_provider = VoiceConfigProvider()
                piper_model = voice_provider.get_voice("piper", piper_language)
                if piper_model:
                    _state.config = _runtime.replace(
                        _state.config,
                        engine="piper",
                        primary_language=piper_language,
                        model_path=_runtime.Path(piper_model) if piper_model else None,
                    )
                    _state.engine_pool.register_engine("piper", _state.config)
                    try:
                        _, piper_engine = await _state.engine_pool.acquire("piper")
                        if piper_engine:
                            print(
                                f"   ✅ Piper loaded: {_runtime.Path(piper_model).name if piper_model else 'modelo default'}"
                            )
                            _state.engine_pool.release("piper", piper_engine)
                            _state.edge_switched_to_piper = True
                            _state.edge_consecutive_failures = 0
                        else:
                            print("   ⚠️ Piper engine could not be loaded")
                    except Exception as e:
                        print(f"   ⚠️ Error loading Piper: {e}")
                else:
                    print("   ⚠️ Piper model not found for this language")
            else:
                print(f"\n⚠️ {_state.edge_consecutive_failures} failures consecutive")
                print("   ⚠️ Piper not installed - fallback is not possible")
    _state._maybe_apply_edge_fallback = _maybe_apply_edge_fallback

    # Three-tier fallback: Edge multilingual → Edge monolingual → Piper
    _state.edge_failure_count = 0
    _state.edge_consecutive_failures = 0
    _state.base_delay = 0.5  # Start with 0.5s delay
    _state.max_delay = 30.0  # Cap at 30s
    _state.edge_switched_to_monolingual = False
    _state.edge_switched_to_piper = False
    _state.config.voice if (_state.config.engine or "").lower() == "edge" else None
    _state.stage_pipeline_enabled = self._is_stage_pipeline_enabled(_state.config)
    _state.stage_pipeline_depth = self._stage_pipeline_depth(_state.config)
    _state.stage_pipeline_queue: Optional[_runtime.asyncio.Queue] = None
    _state.stage_pipeline_task: Optional[_runtime.asyncio.Task] = None
    _state.stage_pipeline_buffer: Dict[int, tuple[str, _runtime.Path, bool]] = {}
    _state.stage_pipeline_done = False
    _state.prefetch_task: Optional[_runtime.asyncio.Task] = None
    _state.prefetch_for_idx: Optional[int] = None

    if _state.stage_pipeline_enabled:
        _state.stage_pipeline_queue = _runtime.asyncio.Queue(maxsize=max(1, _state.stage_pipeline_depth))

        async def _pipeline_producer() -> None:
            assert _state.stage_pipeline_queue is not None
            for pidx, pchapter in enumerate(_state.chapters_list):
                pchapter_num = self._chapter_number(pchapter, pidx + 1)
                pchapter_identity = self._chapter_identity_fields(pchapter, pidx + 1)
                started = _runtime.time.time()
                self._append_runtime_metric(
                    {
                        "event": "pipeline_stage_start",
                        "stage": "prepare",
                        "chapter": pchapter_num,
                        **pchapter_identity,
                    },
                    output_dir=_state.output_dir,
                )
                try:
                    payload = await _runtime.asyncio.to_thread(
                        self._resolve_pre_tts_payload,
                        pchapter,
                        pchapter_num,
                        _state.output_dir,
                        _state.config,
                    )
                    await _state.stage_pipeline_queue.put((pidx, payload, None))
                    self._append_runtime_metric(
                        {
                            "event": "pipeline_stage_done",
                            "stage": "prepare",
                            "chapter": pchapter_num,
                            "elapsed_s": round(_runtime.time.time() - started, 3),
                            **pchapter_identity,
                        },
                        output_dir=_state.output_dir,
                    )
                except Exception as exc:
                    await _state.stage_pipeline_queue.put((pidx, None, exc))
            await _state.stage_pipeline_queue.put((-1, None, None))
        _state._pipeline_producer = _pipeline_producer

        _state.stage_pipeline_task = _runtime.asyncio.create_task(_state._pipeline_producer())
        self._append_runtime_metric(
            {
                "event": "pipeline_enabled",
                "depth": _state.stage_pipeline_depth,
                "chapters": len(_state.chapters_list),
            },
            output_dir=_state.output_dir,
        )

    def _launch_prefetch(next_idx: int) -> None:
        if _state.stage_pipeline_enabled:
            return
        if not self._chapter_prefetch_enabled:
            return
        if next_idx < 0 or next_idx >= len(_state.chapters_list):
            return
        next_chapter = _state.chapters_list[next_idx]
        next_chapter_num = self._chapter_number(next_chapter, next_idx + 1)
        next_chapter_identity = self._chapter_identity_fields(next_chapter, next_idx + 1)
        _state.prefetch_for_idx = next_idx
        _state.prefetch_task = _runtime.asyncio.create_task(
            _runtime.asyncio.to_thread(
                self._resolve_pre_tts_payload,
                next_chapter,
                next_chapter_num,
                _state.output_dir,
                _state.config,
            )
        )
        self._append_runtime_metric(
            {
                "event": "prefetch_request",
                "chapter": next_chapter_num,
                **next_chapter_identity,
            },
            output_dir=_state.output_dir,
        )
    _state._launch_prefetch = _launch_prefetch

    _state.chapter_char_estimates = [max(0, self._estimate_chapter_chars(ch)) for ch in _state.chapters_list]
    if not self._eta_recent_cps:
        _state.baseline_cps = self._load_eta_baseline(_state.config)
        if _state.baseline_cps > 1.0:
            self._eta_recent_cps = [_state.baseline_cps]
    for _state.idx, _state.chapter in enumerate(_state.chapters_list):
        # Adaptive delay and fallback logic for Edge-TTS
        _phase_flow = await _chapter_iteration_preparation(self, _state)
        if _phase_flow is not None:
            if _phase_flow.kind == "break":
                break
            if _phase_flow.kind == "continue":
                continue
            return _phase_flow
        _phase_flow = await _chapter_attempt_coordinator(self, _state)
        if _phase_flow is not None:
            if _phase_flow.kind == "break":
                break
            if _phase_flow.kind == "continue":
                continue
            return _phase_flow

    _state.success = len(_state.errors) == 0
    if _state.stage_pipeline_task is not None:
        _state.stage_pipeline_task.cancel()
        with _runtime.contextlib.suppress(Exception):
            await _state.stage_pipeline_task
    if _state.prefetch_task is not None:
        _state.prefetch_task.cancel()
        with _runtime.contextlib.suppress(Exception):
            await _state.prefetch_task

    # Log Edge-TTS failure statistics if any failures occurred
