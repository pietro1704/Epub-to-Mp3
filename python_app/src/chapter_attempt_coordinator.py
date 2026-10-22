# -*- coding: utf-8 -*-
"""Chapter attempt coordinator."""

from __future__ import annotations

from typing import Optional

from .chapter_attempt_preparation import _chapter_attempt_preparation
from .chapter_engine_recovery import _chapter_engine_recovery
from .chapter_result_recovery import _chapter_result_recovery
from .chapter_synthesis_attempts import _chapter_synthesis_attempts
from .chapter_synthesis_budget import _chapter_synthesis_budget
from .config import ConversionConfig


async def _chapter_attempt_coordinator(self, _state):
    from . import converter as _runtime
    while True:
        _state.chapter_attempt += 1
        _state.chapter_retry = False
        _state.start_time = _runtime.time.time()
        if _state.chapter_attempt > 1:
            _state.base_backoff = min(30, 2 ** min(_state.chapter_attempt, 5))
            # Add ±20% jitter so many chapters failing simultaneously don't
            # retry in lockstep — prevents the Edge rate-limit thundering herd
            # when a whole batch trips 429 at once.
            _state.jitter = _runtime.random.uniform(-0.2, 0.2) * _state.base_backoff
            _state.retry_backoff = max(0.5, _state.base_backoff + _state.jitter)
            self.progress.tick(
                f"⏳ Retry backoff {_state.retry_backoff:.1f}s (attempt {_state.chapter_attempt}/{_state.max_chapter_attempts})"
            )
            await _runtime.asyncio.sleep(_state.retry_backoff)

        def _edge_retry(reason: str, *, count_failure: bool = True) -> None:
            if count_failure:
                _state.edge_failure_count += 1
                _state.edge_consecutive_failures += 1
            _state.chapter_retry = True
            raise _state._RetryChapter(reason)
        _state._edge_retry = _edge_retry

        def _error_text(message: Optional[str]) -> str:
            return message or "Synthesis failed"
        _state._error_text = _error_text

        def _block_edge_connectivity(last_error: Optional[str]) -> None:
            _state.blocked_engines_for_chapter.add("edge")
            # Keep Edge unavailable for the remainder of this sequential pass.
            _state.unavailable_engines.add("edge")
            _state.edge_globally_blocked = True
            _state._trip_edge_circuit("network")
            if not _state.edge_connectivity_recorded:
                self.speed_controller.record_connectivity_failure("edge")
                _state.edge_connectivity_recorded = True
            err_text = str(last_error or "")[:220]
            self._append_runtime_metric(
                {
                    "event": "edge_connectivity_failure",
                    "chapter": _state.chapter_num,
                    "engine": "edge",
                    "error": err_text,
                },
                output_dir=_state.output_dir,
            )
            _state.edge_blocked_chapters_global.update(
                {
                    "__ALL__",
                    str(_state.chapter_num),
                    str(_state.chapter_label or "").strip(),
                    str(getattr(_state.chapter, "name", "") or "").strip(),
                }
            )
            if getattr(_state.config, "extra", None) is None:
                _state.config.extra = {}
            _state.config.extra["edge_blocked_chapters"] = sorted(
                item for item in _state.edge_blocked_chapters_global if item
            )
            self._append_runtime_metric(
                {
                    "event": "edge_blocked_chapter",
                    "chapter": _state.chapter_num,
                    "chapter_label": _state.chapter_label,
                    "engine": "edge",
                    "blocked_size": len(_state.config.extra["edge_blocked_chapters"]),
                },
                output_dir=_state.output_dir,
            )
            with _runtime.contextlib.suppress(Exception):
                from .config import VoiceConfigProvider

                if _state.can_use_piper():
                    piper_language = self._effective_primary_language(_state.config)
                    piper_model = VoiceConfigProvider().get_voice("piper", piper_language)
                    _state.config = _runtime.replace(
                        _state.config,
                        engine="piper",
                        primary_language=piper_language,
                        model_path=_runtime.Path(piper_model) if piper_model else _state.config.model_path,
                    )
                    _state.engine_pool.register_engine("piper", _state.config)
            if (_state.engine_tracker.get("label") or "").lower() == "piper":
                _state.forced_auto_engine = (_state.engine_tracker.get("label") or "").lower()
        _state._block_edge_connectivity = _block_edge_connectivity

        # **RESTORED**: Usar progress tracker (apenas uma vez por chapter)
        if not _state.progress_started:
            self.progress.start_chapter(_state.chapter.name, _state.progress_index)
            _state.progress_started = True

        _state.chapter_success = False
        _state.chapter_error: Optional[str] = None
        _state.chapter_cached = False
        _state.engine_tracker = {"label": (_state.config.engine or "").lower()}
        _state.engine_instance = {"object": None}
        _state.engine_name_used: Optional[str] = None
        _state.engine_obj: Optional[object] = None
        _state.engine_config: Optional[ConversionConfig] = None

        try:
            # Conversion to temp directory
            _phase_flow = await _chapter_attempt_preparation(self, _state)
            if _phase_flow is not None:
                if _phase_flow.kind == "break":
                    break
                if _phase_flow.kind == "continue":
                    continue
                return _phase_flow
            _phase_flow = await _chapter_synthesis_budget(self, _state)
            if _phase_flow is not None:
                if _phase_flow.kind == "break":
                    break
                if _phase_flow.kind == "continue":
                    continue
                return _phase_flow
            _phase_flow = await _chapter_synthesis_attempts(self, _state)
            if _phase_flow is not None:
                if _phase_flow.kind == "break":
                    break
                if _phase_flow.kind == "continue":
                    continue
                return _phase_flow
            _phase_flow = await _chapter_engine_recovery(self, _state)
            if _phase_flow is not None:
                if _phase_flow.kind == "break":
                    break
                if _phase_flow.kind == "continue":
                    continue
                return _phase_flow
            _phase_flow = await _chapter_result_recovery(self, _state)
            if _phase_flow is not None:
                if _phase_flow.kind == "break":
                    break
                if _phase_flow.kind == "continue":
                    continue
                return _phase_flow
                    # **CONTINUE** - never skip chapter, just mark as error

        except _state._RetryChapter as retry_exc:
            _state.retry_exc = retry_exc
            _state.chapter_retry = True
            _state.chapter_error = str(_state.retry_exc)
            # Terminal categories (auth, no engine available) won't be fixed
            # by retrying — stop early so the defer/fallback logic kicks in.
            _state.terminal_category = _runtime.classify_error(_state.chapter_error)
            if _state.terminal_category in ("auth", "engine_unavailable"):
                if self.verbose:
                    print(
                        f"   ⛔ Terminal error ({_state.terminal_category}), skipping retries: {_state.chapter_error}"
                    )
                _state.chapter_attempt = _state.max_chapter_attempts
        except Exception as e:
            _state.e = e
            _state.error_msg = f"Exception: {str(_state.e)}"
            if self.verbose:
                print(f"   ❌ EXCEPTION ERROR: {_state.error_msg}")
            _state.chapter_error = _state.error_msg
            if (_state.engine_tracker.get("label") or (_state.config.engine or "").lower()) == "edge":
                _state._edge_retry(_state.error_msg)
            _state.errors.append(f"{_state.chapter.name}: {_state.error_msg}")
            _state.error_msg = _state._error_text(_state.error_msg)
            self.progress.complete_chapter(f"❌ {_state.error_msg}")
            # **CONTINUE** - log error but continue processing other chapters
        finally:
            if _state.engine_obj is not None and _state.engine_name_used:
                _state.engine_pool.release(_state.engine_name_used, _state.engine_obj)
                _state.engine_obj = None
                _state.engine_name_used = None

        if _state.chapter_retry:
            if _state.chapter_attempt >= _state.max_chapter_attempts:
                if not _state.deferred_safe_pass:
                    # Defer hard chapters to the end once, then retry in safe mode.
                    setattr(_state.chapter, "_deferred_safe_pass", True)
                    _state.chapters_list.append(_state.chapter)
                    self.progress.complete_chapter(
                        "⏭️ Deferred to end for safe offline retry"
                    )
                    break
                _state.chapter_error = _state.chapter_error or "Persistent failure"
                _state.errors.append(f"{_state.chapter.name}: {_state.chapter_error}")
                _state.chapter_error = _state._error_text(_state.chapter_error)
                self.progress.complete_chapter(f"❌ {_state.chapter_error}")
                break
            await _state._maybe_apply_edge_fallback()
            continue

        _state.elapsed = _runtime.time.time() - _state.start_time
        _state.message = self.speed_controller.after_chapter(
            _state.engine_tracker.get("label") or (_state.config.engine or "").lower(),
            chapter_index=_state.chapter_num,
            chapter_name=_state.chapter_label,
            chapter_chars=_state.chapter_chars,
            elapsed=_state.elapsed,
            success=_state.chapter_success,
            error=_state.chapter_error,
            from_cache=_state.chapter_cached,
            tts_engine=_state.engine_instance.get("object"),
        )
        if _state.message:
            print(_state.message)
        _state.chapter_identity = self._chapter_identity_fields(_state.chapter, _state.idx + 1)
        self._append_runtime_metric(
            {
                "event": "chapter_complete",
                "chapter": _state.chapter_num,
                "engine": _state.engine_tracker.get("label") or (_state.config.engine or "").lower(),
                "chars": _state.chapter_chars,
                "elapsed_s": round(float(_state.elapsed), 3),
                "success": bool(_state.chapter_success),
                "cached": bool(_state.chapter_cached),
                "attempt": _state.chapter_attempt,
                "error": (_state.chapter_error or "")[:240] if _state.chapter_error else "",
                **_state.chapter_identity,
            },
            output_dir=_state.output_dir,
        )
        self._persist_engine_params_after_chapter(
            cfg=_state.engine_config if _state.engine_config is not None else _state.config,
            engine_label=_state.engine_tracker.get("label") or (_state.config.engine or "").lower(),
            chapter_chars=_state.chapter_chars,
            elapsed_s=_state.elapsed,
            success=_state.chapter_success and not _state.chapter_cached,
        )
        if (_state.engine_tracker.get("label") or "").lower() == "edge" and _state.chapter_success:
            _state._reset_edge_circuit()
        if _state.chapter_success and not _state.chapter_cached:
            self._maybe_exit_edge_slow_mode(
                engine_label=_state.engine_tracker.get("label") or (_state.config.engine or "").lower(),
                chapter_chars=_state.chapter_chars,
                elapsed=_state.elapsed,
                engine_pool=_state.engine_pool,
                engine_obj=_state.engine_instance.get("object"),
            )
        self._mark_health_progress(_state.chapter_num, _state.chapter_success, _state.elapsed, _state.chapter_error)
        try:
            from .session_logger import log_chapter_error, log_chapter_perf
            _state.log_chapter_error = log_chapter_error
            _state.log_chapter_perf = log_chapter_perf

            _state._engine_label = _state.engine_tracker.get("label") or (_state.config.engine or "").lower()
            _state._book = (
                getattr(self._active_config, "book_title", None)
                or getattr(_state.config, "book_title", "")
                or ""
            )
            if _state.chapter_success and not _state.chapter_cached:
                _state.log_chapter_perf(
                    book_title=_state._book,
                    chapter_index=_state.chapter_num,
                    chapter_name=_state.chapter_label,
                    engine=_state._engine_label,
                    elapsed_seconds=float(_state.elapsed or 0.0),
                    char_count=int(_state.chapter_chars or 0),
                    chapter_id=_state.chapter_identity["chapter_id"],
                )
            elif not _state.chapter_success:
                _state.log_chapter_error(
                    book_title=_state._book,
                    chapter_index=_state.chapter_num,
                    chapter_name=_state.chapter_label,
                    engine=_state._engine_label,
                    error=_state.chapter_error or "",
                    elapsed_seconds=float(_state.elapsed or 0.0),
                    chapter_id=_state.chapter_identity["chapter_id"],
                )
        except Exception:
            pass
        self._record_chapter_progress(
            _state.chapter,
            _state.chapter_success,
            _state.chapter_error,
        )
        _state.policy_getter = getattr(_state.engine_obj, "get_segment_policy_state", None)
        if callable(_state.policy_getter):
            with _runtime.contextlib.suppress(Exception):
                _state.policy_state = _state.policy_getter()
                if isinstance(_state.policy_state, dict):
                    self._segment_adaptive_state["segment_duration_policy"] = _state.policy_state
        self._save_conversion_checkpoint(
            _state.chapter_num, _state.output_dir, _state.config, success=_state.chapter_success
        )
        if self._adaptive_checkpoint_enabled:
            self._adaptive_checkpoint_dirty += 1
            if self._adaptive_checkpoint_dirty >= self._adaptive_checkpoint_interval:
                self._save_adaptive_state_checkpoint(_state.output_dir)
        break
