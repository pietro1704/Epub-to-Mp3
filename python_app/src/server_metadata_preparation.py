# -*- coding: utf-8 -*-
"""Server metadata preparation."""

from __future__ import annotations

from pathlib import Path
from typing import Optional

from .config import ConversionConfig
from .ebook_reader import Chapter


async def _server_metadata_preparation(_runtime, _state):
    def tts_log_callback(message: str) -> None:
        """Capture verbose TTS output and add to raw log + statusHint."""
        raw_log = _state.job.setdefault("_raw_log", [])
        raw_log.append(message)
        # Show important status messages in UI (model loading, tuning, retry)
        status_keywords = [
            # Loading/downloading
            "loading",
            "download",
            "model",
            "ready",
            # Tuning and retry
            "tuning",
            "adjust",
            "chunk",
            "retry",
            "trying",
            "rate limit",
            "waiting",
            "backoff",
            "divid",
            "recover",
            "segment",
            "reduc",
            "optim",
            # Warmup and config
            "warmup",
            "config",
            "parallel",
            "concurr",
        ]
        if any(kw in message.lower() for kw in status_keywords):
            _state.job["statusHint"] = message
            # Also append to events for visibility
            _runtime._append_event(_state.job, f"🔧 {message}")
    _state.tts_log_callback = tts_log_callback

    # Resolve per-book/per-engine roots
    _state.book_slug = _runtime._book_slug(_state.job.get("bookTitle"), _state.job.get("file_path"))
    _state.output_root = _runtime.Path(_state.job.get("outputDir") or (_runtime.output_dir / _state.book_slug))
    _state.cache_root = _runtime.Path(_state.job.get("cacheDir") or (_runtime.CACHE_DIR / _state.book_slug))

    # Create TTS engine using factory with optimized compression
    _state.model_path = _runtime.Path(_state.job.get("model")) if _state.job.get("model") else None
    # Treat "auto" as "edge" (auto mode removed - edge is now default)
    _state.requested_engine = _state.job.get("engine", "edge")
    if (_state.requested_engine or "").lower() == "auto":
        _state.requested_engine = "edge"
    _state.priority_selectors = (
        _state.converter_app._expand_selector_args([_state.job.get("priority")])
        if _state.job.get("priority")
        else []
    )
    _state.config = _runtime.ConversionConfig(
        engine=_state.requested_engine,
        job_id=_state.job_id,
        voice=_state.job.get("voice"),
        model_path=_state.model_path,
        primary_language=_state.detected_lang or "auto",
        output_dir=str(_state.output_root),
        cache_dir=str(_state.cache_root),
        preserve_all_chapters=not _state.filter_chapters_flag,
        # Optimized compression for web delivery (reduce file size & bandwidth)
        bitrate=_state.job.get("bitrate") or "8k",  # 8 kbps - good quality for voice, ~3.6 MB/hour
        sample_rate=_state.job.get("sampleRate") or 16_000,  # 16 kHz - sufficient for speech
        channels=_state.job.get("channels") or 1,  # Mono - audiobooks don't need stereo
        force_reprocess=bool(_state.job.get("forceReprocess")),
        clear_cache=_state.clear_cache_flag,
        footnote_mode=_state.job.get("footnote_mode") or "inline",
        footnote_context_words=_state.converter_app.FOOTNOTE_CONTEXT_WORDS,
        priority_selectors=_state.priority_selectors,
        speak_formatting_cues=_state.job.get("formattingCues", True),
        formatting_locale=_runtime._normalize_locale(_state.job.get("uiLanguage"), "pt"),
        piper_max_procs=_state.piper_procs_override,
        engine_chain_fallback=_state.job.get("engineChainFallback"),
        verbose=_state.verbose_enabled,  # Enable verbose logging for terminal-like output
        log_callback=_state.tts_log_callback,  # Capture all verbose logs
        enable_character_voices=bool(_state.job.get("enableCharacterVoices", True)),
        narrator_voice=_state.job.get("narratorVoice"),
        character_voice=_state.job.get("characterVoice"),
    )
    _state.config.use_language_detection = (
        True if _state.use_language_detection_flag is None else bool(_state.use_language_detection_flag)
    )
    _state.config.prioritize_primary_language = (
        True if _state.prioritize_primary_flag is None else bool(_state.prioritize_primary_flag)
    )
    if _state.edge_auto_tune_override is not None:
        _state.config.edge_auto_tune = bool(_state.edge_auto_tune_override)
    if _state.edge_stable_mode is not None:
        _state.config.extra["edge_stable_mode"] = "1" if _state.edge_stable_mode else "0"
    if _state.job.get("multiEngineParallel"):
        _state.config.extra["multi_engine_parallel"] = "1"
    _state.config.extra.setdefault("voice_auto", "1" if _state.job.get("voice") is None else "0")
    _state.converter_app._apply_language_preferences(_state.config)

    _state.chapters = await _state.loop.run_in_executor(None, lambda: list(_state.reader.get_chapters()))
    if _state.structure_items:

        def _apply_transforms() -> list:
            _state.structure_items = _state.converter_app._apply_text_transforms(
                _state.structure_items, _state.config, _state.reader
            )
            _state.converter_app._apply_structure_to_reader(_state.reader, _state.structure_items)
            return (
                _state.reader.get_chapter_structure(preserve_all=_state.config.preserve_all_chapters)
                or _state.reader.get_chapters()
            )
        _state._apply_transforms = _apply_transforms

        _state.chapters = await _state.loop.run_in_executor(None, _state._apply_transforms)
    if _state.config.priority_selectors:
        _state.chapters = _runtime._apply_priority_order(_state.chapters, _state.config.priority_selectors)
    _runtime._append_event(_state.job, f"✅ {len(_state.chapters)} chapters found")
    _runtime._update_job_activity(_state.job, stage="chapters_ready")
    if (_state.config.engine or "").lower() == "edge":
        # Pre-warm Edge-TTS while the rest of the chapter setup runs.
        # Best-effort fire-and-forget: TLS handshake + first-request
        # latency is ~300-500ms and can run in parallel with config
        # tuning below. Failures are silent — chapter loop's normal
        # rate-limit handling still applies on the real first request.
        try:
            from src.tts.edge_engine import prewarm_edge as _prewarm_edge
            _state._prewarm_edge = _prewarm_edge

            _state._voice_pick = _state.config.voice or "en-US-AriaNeural"
            _runtime.asyncio.create_task(_state._prewarm_edge(_state._voice_pick))
        except Exception:
            pass

        # **PERFORMANCE OPTIMIZATIONS**: Use auto-tuned Edge profile from hardware/network detector
        def _env_int(name: str, fallback: int) -> int:
            raw = _runtime.os.getenv(name, "").strip()
            try:
                return int(raw) if raw else fallback
            except ValueError:
                return fallback
        _state._env_int = _env_int

        _state.config.edge_aggressive_mode = False  # Aggressive mode conflicts with tuned parallelism
        if _state.edge_parallel_override is not None:
            _state.config.edge_enable_parallel = bool(_state.edge_parallel_override)
        else:
            _state.config.edge_enable_parallel = _runtime.os.getenv("EDGE_ENABLE_PARALLEL", "true").lower() in (
                "true",
                "1",
                "yes",
            )
        if _state.edge_chunk_override is not None:
            _state.config.edge_chunk_chars = int(_state.edge_chunk_override)
        else:
            # Research-based default: 8k chars
            _state.config.edge_chunk_chars = _state._env_int(
                "EDGE_CHUNK_CHARS", _state.config.edge_chunk_chars or 8000
            )
        if _state.edge_segment_override is not None:
            _state.config.edge_max_segment_seconds = int(_state.edge_segment_override)
        else:
            _state.config.edge_max_segment_seconds = _state._env_int(
                "EDGE_MAX_SEGMENT_SECONDS", _state.config.edge_max_segment_seconds or 75
            )
    _state.force_sequential = bool(_state.job.get("noParallel")) or _state.edge_stable_mode
    if _state.force_sequential:
        _state.config.edge_enable_parallel = False

    def _apply_engine_overrides(target: ConversionConfig) -> None:
        if _state.edge_chunk_override is not None:
            target.edge_chunk_chars = int(_state.edge_chunk_override)
        if _state.edge_segment_override is not None:
            target.edge_max_segment_seconds = int(_state.edge_segment_override)
        if _state.edge_parallel_override is not None:
            target.edge_enable_parallel = bool(_state.edge_parallel_override)
        if _state.piper_procs_override is not None:
            target.piper_max_procs = int(_state.piper_procs_override)
    _state._apply_engine_overrides = _apply_engine_overrides

    _state._apply_engine_overrides(_state.config)
    if _state.force_sequential:
        _state.config.edge_enable_parallel = False

    # Store original before deduplication for potential restoration
    _state.original_chapters = _state.chapters.copy()

    _state.chapters, _state.duplicates_removed = _runtime.deduplicate_chapters_by_content(_state.chapters)
    if _state.duplicates_removed:
        _runtime._append_event(_state.job, f"🧹 Duplicate chapter detected: {_state.duplicates_removed} removed")

    # Validate chapter count against TOC
    _state.expected_count = getattr(_state.reader, "_toc_expected_chapters", 0)
    if _state.expected_count > 0 and len(_state.chapters) != _state.expected_count and _state.duplicates_removed > 0:
        if len(_state.chapters) + _state.duplicates_removed == _state.expected_count:
            _runtime._append_event(
                _state.job,
                f"⚠️  VALIDATION: TOC reports {_state.expected_count} chapters, but detected {len(_state.chapters)}",
            )
            _runtime._append_event(
                _state.job,
                f"🔄 Auto-fix: restoring {_state.duplicates_removed} removed chapter(s)",
            )
            _state.chapters = _state.original_chapters
    try:
        _runtime._enforce_chapter_limit(len(_state.chapters))
    except _runtime.HTTPException as limit_error:
        _state.limit_error = limit_error
        _runtime._append_event(_state.job, f"❌ {_state.limit_error.detail}")
        _runtime._persist_job(_state.job_id, force=True)
        raise
    _state.selection_note = " (filter applied)" if _state.selector_text else ""
    _runtime._append_event(_state.job, f"📊 Chapters: {len(_state.chapters)}{_state.selection_note}")
    _state.job["chaptersTotal"] = len(_state.chapters)
    _state.chapter_char_totals: dict[int, int] = {}
    _state.total_chars = 0
    for _state.idx, _state.chapter in enumerate(_state.chapters, 1):
        _state.chapter_text = getattr(_state.chapter, "speech_text", None) or _state.chapter.text or ""
        _state.clean_text = _runtime.TextFormattingProcessor.strip_inline_markdown(_state.chapter_text)
        _state.chapter_chars = len(_state.clean_text)
        _state.chapter_char_totals[_state.idx] = _state.chapter_chars
        _state.total_chars += _state.chapter_chars
    _state.job["totalChars"] = _state.total_chars
    _state.job["processedChars"] = 0

    # Detect size outliers (chapters >5× median) and warn before conversion starts.
    if _state.chapter_char_totals:
        _state.sorted_lengths = sorted(_state.chapter_char_totals.values())
        _state.median_chars = _state.sorted_lengths[len(_state.sorted_lengths) // 2]
        _state.outlier_floor = 50_000
        _state.outlier_threshold = max(_state.median_chars * 5, _state.outlier_floor)
        for _state.idx, _state.ch_chars in _state.chapter_char_totals.items():
            if _state.ch_chars > _state.outlier_threshold and _state.ch_chars > _state.outlier_floor:
                _state.ch = _state.chapters[_state.idx - 1] if 0 < _state.idx <= len(_state.chapters) else None
                _state.ch_name = getattr(_state.ch, "name", f"Chapter {_state.idx}")[:60] if _state.ch else f"Chapter {_state.idx}"
                _state.ratio = _state.ch_chars // max(_state.median_chars, 1)
                (_state.ch_chars // 1000) * 1000
                _runtime._append_event(
                    _state.job,
                    f"⚠️ Oversized chapter [{_state.idx}]: {_state.ch_name}"
                    f" ({_state.ch_chars:,} chars = {_state.ratio}× median)"
                    f" — conversion will take longer for this chapter",
                )

    _state.job["_chapterCharTotals"] = _state.chapter_char_totals
    _state.job["_chapterCharProcessed"] = {idx: 0 for idx in _state.chapter_char_totals}
    _state.job["_chapterLastProgressUpdate"] = {idx: 0.0 for idx in _state.chapter_char_totals}
    _state.job["_lastProgressBroadcast"] = 0.0

    def _recalculate_progress() -> float:
        return _runtime.recalculate_progress(_state.job, len(_state.chapters))
    _state._recalculate_progress = _recalculate_progress

    def _broadcast_progress(force: bool = False) -> None:
        _runtime.broadcast_progress(_state.job, force=force)
    _state._broadcast_progress = _broadcast_progress

    def _update_job_progress(force_broadcast: bool = False) -> None:
        _runtime.update_job_progress(_state.job, len(_state.chapters), force_broadcast=force_broadcast)
    _state._update_job_progress = _update_job_progress

    def _advance_chapter_progress(
        chapter_index: int,
        segment_text: str,
        total_text_chars: Optional[int] = None,
    ) -> None:
        _runtime._update_job_activity(_state.job)
        _runtime.advance_chapter_progress(
            _state.job, chapter_index, segment_text, len(_state.chapters), total_text_chars
        )
    _state._advance_chapter_progress = _advance_chapter_progress

    def _complete_chapter_progress(
        chapter_index: int,
        *,
        broadcast: bool = True,
        output_path: Optional[Path] = None,
    ) -> None:
        _runtime.complete_chapter_progress(
            _state.job,
            chapter_index,
            len(_state.chapters),
            broadcast=broadcast,
            output_path=output_path,
        )
    _state._complete_chapter_progress = _complete_chapter_progress
