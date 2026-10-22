# -*- coding: utf-8 -*-
"""Server chapter preparation."""

from __future__ import annotations

from pathlib import Path
from typing import Optional

from .conversion_control import ConversionControl as _ConversionControl


async def _server_chapter_preparation(_runtime, _state, _chapter):
    if _chapter.attempt > 1:
        _runtime._append_event(
            _state.job,
            f"🔁 Reprocessing chapter {_chapter.idx}/{len(_state.chapters)} (attempt {_chapter.attempt}/{_state.max_chapter_attempts_label})",
        )
        # Set retrying status with info
        _runtime._set_chapter_status(
            _state.job,
            _chapter.idx,
            "retrying",
            engine_label=(_state.config.engine or "auto"),
            retry_count=_chapter.attempt - 1,
            max_retries=_state.max_chapter_attempts,
            retry_reason="Previous failure",
            param_adjustment="Reduced parameters",
        )
    else:
        _runtime._set_chapter_status(
            _state.job,
            _chapter.idx,
            "processing",
            engine_label=(_state.config.engine or "auto"),
        )
    _runtime._append_event(_state.job, "")
    _runtime._append_event(_state.job, f"🎯 Converting chapter {_chapter.idx}/{len(_state.chapters)}: {_chapter.chapter_name}")

    _chapter.safe_name = _runtime.FileManager.sanitize_filename(_chapter.chapter_name)
    _chapter.output_file = _state.job_output_dir / f"{_chapter.idx:03d} - {_chapter.safe_name}.mp3"
    _chapter.chapter_text = getattr(_chapter.chapter_obj, "speech_text", None) or _chapter.chapter_obj.text or ""

    if not _chapter.chapter_text or not _chapter.chapter_text.strip():
        _runtime._append_event(_state.job, "⚠️ Chapter has no audible content, skipped")
        _runtime._set_chapter_status(_state.job, _chapter.idx, "skipped")
        _state._refresh_chapter_completion()
        _state._complete_chapter_progress(_chapter.idx)
        _runtime._update_job_activity(_state.job, stage=f"chapter_{_chapter.idx}_skipped")
        return _ConversionControl("return", None)

    _chapter.clean_text = _runtime.TextFormattingProcessor.strip_inline_markdown(_chapter.chapter_text)

    if _runtime.MAX_CHAPTER_CHARS > 0 and len(_chapter.clean_text) > _runtime.MAX_CHAPTER_CHARS:
        _runtime._append_event(
            _state.job,
            f"⏭️ Skipping chapter {_chapter.idx} ({len(_chapter.clean_text):,} chars >"
            f" MAX_CHAPTER_CHARS={_runtime.MAX_CHAPTER_CHARS:,}): {_chapter.chapter_name[:60]}",
        )
        _runtime._set_chapter_status(_state.job, _chapter.idx, "skipped")
        _state._refresh_chapter_completion()
        _state._complete_chapter_progress(_chapter.idx)
        _runtime._update_job_activity(_state.job, stage=f"chapter_{_chapter.idx}_skipped_oversized")
        return _ConversionControl("return", None)

    _chapter.preview = _runtime._build_text_preview(_chapter.clean_text)
    if _chapter.preview:
        _runtime._append_event(_state.job, f"📝 Excerpt: {_chapter.preview}")

    # Per-chapter segment progress counter — the canonical
    # heartbeat that the idle watchdog monitors.  It is a plain
    # dict so the watchdog can read it without closing over the
    # synthesis-scoped int.
    _chapter._segment_progress_state: dict = {"hits": 0}

    def _progress_callback(segment_text: str, total_text_chars: int = 0) -> None:
        _chapter._segment_progress_state["hits"] = int(_chapter._segment_progress_state["hits"]) + 1
        _state._advance_chapter_progress(_chapter.idx, segment_text, total_text_chars)
    _chapter._progress_callback = _progress_callback

    # Streaming: use a single per-job directory with chapter-prefixed files
    _chapter.stream_dir = _runtime._job_stream_dir(_state.job_id, ensure=True)
    _chapter.stream_index = _runtime._load_stream_index(_state.job_id)
    _chapter.chapter_key = str(_chapter.idx)
    try:
        with _runtime._stream_manifest_lock:
            _chapter.stream_index = _runtime._load_stream_index(_state.job_id)
            _chapter.previous_chapter = _chapter.stream_index.get("chapters", {}).get(_chapter.chapter_key) or {}
            _chapter.retired = _runtime._retired_stream_chunks(_chapter.previous_chapter)
            _chapter.stream_index.setdefault("chapters", {})[_chapter.chapter_key] = {
                "chapterIndex": _chapter.idx,
                "chunks": [],
                "retiredChunks": _chapter.retired,
            }
            _runtime._save_stream_index(_state.job_id, _chapter.stream_index)
    except Exception:
        pass

    # In-memory manifest — avoids a read-modify-write per segment
    _chapter._manifest_chunks: dict[int, dict] = {}

    def _chunk_callback(
        segment_index: int, temp_path: Path, segment_text: str = "", *, observation=None
    ) -> None:
        """Save synthesized segment for streaming playback."""
        published_target = None
        previous_chunk = _chapter._manifest_chunks.get(segment_index)
        try:
            # A publication identity must not alias a replacement's
            # bytes when a client still holds an earlier manifest.
            chunk_id = _runtime.uuid.uuid4().hex
            target_name = f"stream_{_runtime.uuid.uuid4().hex}{temp_path.suffix.lower()}"
            target = _runtime._resolve_relative_path_within_root(
                _chapter.stream_dir, target_name, must_exist=False
            )
            if observation is None:
                raise RuntimeError("Missing segment publication context")
            observation_payload = observation.publish_audio(temp_path, target)
            published_target = target
            chunk_entry: dict = {
                "id": chunk_id,
                "index": segment_index,
                "file": target.name,
                "url": f"/api/streams/{_state.job_id}/chapters/{_chapter.idx}/chunks/{chunk_id}",
                "observation": observation_payload,
            }
            if segment_text:
                chunk_entry["text"] = segment_text
            _chapter._manifest_chunks[segment_index] = chunk_entry
            with _runtime._stream_manifest_lock:
                stream_index = _runtime._load_stream_index(_state.job_id)
                stream_index.setdefault("jobId", _state.job_id)
                previous_chapter = stream_index.get("chapters", {}).get(_chapter.chapter_key) or {}
                active_ids = frozenset(chunk["id"] for chunk in _chapter._manifest_chunks.values())
                retired = _runtime._retired_stream_chunks(previous_chapter, active_ids)
                stream_index.setdefault("chapters", {})[_chapter.chapter_key] = {
                    "chapterIndex": _chapter.idx,
                    "retiredChunks": retired,
                    "chunks": sorted(
                        _chapter._manifest_chunks.values(), key=lambda x: x.get("index", 0)
                    ),
                    "updatedAt": _runtime.time.time(),
                    "baseUrl": f"/api/streams/{_state.job_id}/chapters/{_chapter.idx}",
                }
                _runtime._save_stream_index(_state.job_id, stream_index)
            published_target = None
        except Exception as exc:
            if previous_chunk is None:
                _chapter._manifest_chunks.pop(segment_index, None)
            else:
                _chapter._manifest_chunks[segment_index] = previous_chunk
            if published_target is not None:
                with _runtime.contextlib.suppress(OSError):
                    published_target.unlink(missing_ok=True)
            _runtime.logger.debug("Chunk callback error for segment %d: %s", segment_index, exc)
    _chapter._chunk_callback = _chunk_callback

    _chapter.auto_order: list[str] = []
    _chapter.attempted_auto: set[str] = set()
    _chapter.engine_runtime: Optional[float] = None
    _chapter.local_active_config = _state.active_config
    _chapter.local_engine_name = (
        _chapter.local_active_config.engine if _chapter.local_active_config else _state.config.engine
    ) or "auto"

    # Multi-engine parallel: honour slot affinity when the preferred
    # engine is available and the job is not in auto-mode.
    if _chapter.preferred_engine and not _state.auto_mode:
        _chapter.pref_lower = _chapter.preferred_engine.lower()
        if _chapter.pref_lower not in _state.unavailable_engines:
            for _chapter._candidate in _state.engine_chain:
                if (_chapter._candidate.engine or "").lower() == _chapter.pref_lower:
                    _chapter.local_active_config = _chapter._candidate
                    _chapter.local_engine_name = _chapter.pref_lower
                    break

    if _state.auto_mode:
        _chapter.available_auto = _state._available_auto_pool()
        if not _chapter.available_auto:
            _runtime._append_event(_state.job, "❌ No engine available in automatic mode")
            _state.job_failed["value"] = True
            return _ConversionControl("return", None)
        if not _state.telemetry_speeds:
            _chapter.summary = _runtime.telemetry.summary()
            _state.telemetry_speeds.update(_chapter.summary)
        _chapter.selected_engine, _chapter.auto_order = _runtime._pick_auto_engine(
            len(_chapter.clean_text),
            _runtime.TextValidator.estimate_duration(_chapter.clean_text),
            _chapter.available_auto,
            telemetry_speeds=_state.telemetry_speeds,
            preferred_engine=_state.preferred_auto_engine,
        )
        _chapter.attempted_auto.add(_chapter.selected_engine)
        _chapter.local_engine_name = _chapter.selected_engine
        _chapter.local_active_config = _chapter.available_auto[_chapter.selected_engine]
        _runtime._append_event(_state.job, f"⚡ AUTO: using {_chapter.selected_engine.upper()} for this chapter")
        _runtime._set_chapter_status(
            _state.job,
            _chapter.idx,
            "processing",
            engine_label=_chapter.selected_engine,
        )
        _chapter.est = _runtime.TextValidator.estimate_duration(_chapter.clean_text)
        if _chapter.est <= 0:
            _chapter.est = max(len(_chapter.clean_text) / 15.0, 30.0)
        _runtime._append_event(
            _state.job,
            f"   ↳ Text: {len(_chapter.clean_text)} chars, estimated {_runtime.TimeFormatter.format_time(_chapter.est)}",
        )

    _chapter.estimated_seconds = _runtime.TextValidator.estimate_duration(_chapter.clean_text)
    if _chapter.estimated_seconds <= 0:
        _chapter.estimated_seconds = max(len(_chapter.clean_text) / 15.0, 30.0)

    _chapter.retry_count = 0

    def _edge_retry_adjustments(edge_config, attempt: int) -> dict[str, float]:
        return _runtime.edge_retry_adjustments(edge_config, attempt)
    _chapter._edge_retry_adjustments = _edge_retry_adjustments

    async def _maybe_retry(
        *,
        reason: str,
        engine_label: str,
        engine_obj,
        engine_config,
    ) -> bool:
        # Stop retrying engines flagged as unavailable (e.g. Edge after
        # the job-wide timeout threshold). Without this guard the loop
        # would keep retrying the same dead engine for every remaining
        # chapter, burning _CHAPTER_RETRY_MAX timeouts each time.
        if _runtime._engine_is_disabled(engine_label, _state.unavailable_engines):
            return False
        # Give Edge one local safe-mode retry before switching to slower
        # offline engines. This preserves Edge for as long as possible
        # without keeping it enabled after repeated hard failures.
        if _state.engine_index + 1 < len(
            _state.engine_chain
        ) and not _runtime._should_retry_edge_before_fallback(engine_label, _state.edge_slow_mode):
            return False
        if _runtime._CHAPTER_RETRY_MAX <= 0 or _chapter.retry_count >= _runtime._CHAPTER_RETRY_MAX:
            return False
        # Short-circuit terminal categories — retrying an auth failure or
        # an engine flagged unavailable just burns the retry budget.
        # Fall through to the next engine in the chain instead.
        category = _runtime.classify_error(reason)
        if category in ("auth", "engine_unavailable"):
            _runtime._append_event(
                _state.job,
                f"⛔ Skipping retry for terminal error ({category}): {reason}",
            )
            return False
        _chapter.retry_count += 1
        backoff = _runtime._CHAPTER_RETRY_BACKOFF_SECONDS * (1 + 0.5 * (_chapter.retry_count - 1))
        # Jitter ±20% so simultaneous chapter failures don't retry in lockstep
        # and collide on Edge rate limits.
        backoff = max(0.0, backoff + _runtime.random.uniform(-0.2, 0.2) * backoff)
        if (engine_label or "").lower() == "edge":
            _state._apply_edge_slow_mode(reason)
            adjustments = _chapter._edge_retry_adjustments(engine_config, _chapter.retry_count)
            if hasattr(engine_obj, "apply_speed_profile"):
                try:
                    engine_obj.apply_speed_profile(**adjustments)
                except Exception:
                    pass
            engine_config.edge_chunk_chars = int(adjustments["chunk_char_limit"])
            engine_config.edge_max_segment_seconds = int(
                adjustments["max_segment_seconds"]
            )
            engine_config.edge_enable_parallel = False
            _state.config.edge_chunk_chars = engine_config.edge_chunk_chars
            _state.config.edge_max_segment_seconds = engine_config.edge_max_segment_seconds
            _state.config.edge_enable_parallel = engine_config.edge_enable_parallel
            _runtime._append_event(
                _state.job,
                f"🔧 Edge fallback: chunk={engine_config.edge_chunk_chars} seg={engine_config.edge_max_segment_seconds}s parallel=off",
            )
        if _state.parallel_slots > 1:
            _state.parallel_slots = max(1, _state.parallel_slots - 1)
            _state.engine_pool.update_parallel_slots(_state.parallel_slots)
            _state.job["parallelSlots"] = _state.parallel_slots
            _runtime._append_event(
                _state.job,
                f"⚙️ Reducing parallelism to {_state.parallel_slots} after {reason}",
            )
        if backoff > 0:
            await _runtime.asyncio.sleep(backoff)
        _runtime._append_event(
            _state.job,
            f"🔁 Retrying ({_chapter.retry_count}/{_runtime._CHAPTER_RETRY_MAX}) after {reason}",
        )
        return True
    _chapter._maybe_retry = _maybe_retry
