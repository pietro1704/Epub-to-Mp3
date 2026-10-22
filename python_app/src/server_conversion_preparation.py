# -*- coding: utf-8 -*-
"""Server conversion preparation."""

from __future__ import annotations

from typing import Optional

from .conversion_control import ConversionControl as _ConversionControl


async def _server_conversion_preparation(_runtime, _state):
    if _state._should_abort_current_run("🛑 Conversion cancelled before start"):
        return _ConversionControl("return", None)

    _state.job["state"] = "running"
    _state.job["statusHint"] = "Preparing conversion..."

    # Reset adaptive Edge TTS settings for new conversion
    _runtime.reset_adaptive_settings()

    _runtime._append_event(_state.job, "📚 EBOOK METADATA")
    _runtime._append_event(_state.job, "=" * 64)
    _runtime._persist_job(_state.job_id, force=True)  # Persist state change
    _runtime._schedule_job_broadcast(_state.job_id, _state.job)  # Broadcast running state to UI immediately
    _runtime._update_job_activity(_state.job, stage="metadata")

    _state.file_path = _runtime.Path(_state.job["file_path"])
    _state.max_performance = bool(_state.job.get("maxPerformance"))
    _state.filter_chapters_flag = bool(_state.job.get("filterChapters"))
    _state.clear_cache_flag = bool(_state.job.get("clearCache"))
    _state.force_reprocess_flag = bool(_state.job.get("forceReprocess"))
    _state.verbose_flag = _state.job.get("verbose")
    _state.use_language_detection_flag = _state.job.get("useLanguageDetection")
    _state.prioritize_primary_flag = _state.job.get("prioritizePrimaryLanguage")
    _state.edge_chunk_override = _state.job.get("edgeChunkChars")
    _state.edge_segment_override = _state.job.get("edgeMaxSegmentSeconds")
    _state.edge_parallel_override = _state.job.get("edgeEnableParallel")
    _state.edge_auto_tune_override = _state.job.get("edgeAutoTune")
    _state.edge_stable_mode = _state.job.get("edgeStableMode")
    _state.chapter_stall_seconds = _state.job.get("chapterStallSeconds")
    _state.edge_network_tier = _state.job.get("edgeNetworkTier")
    _state.piper_procs_override = _state.job.get("piperMaxProcs")

    if _state.max_performance:
        if _state.edge_chunk_override is None:
            _state.edge_chunk_override = 24000
        if _state.edge_segment_override is None:
            _state.edge_segment_override = 300
        if _state.edge_parallel_override is None:
            _state.edge_parallel_override = True
        if _state.piper_procs_override is None:
            _state.cpu_physical = int(getattr(_runtime._hardware_profile, "cpu_physical", 2) or 2)
            _state.piper_procs_override = min(6, max(1, _state.cpu_physical))

    if _state.edge_stable_mode:
        if _state.edge_chunk_override is None:
            _state.edge_chunk_override = 4000
        if _state.edge_segment_override is None:
            _state.edge_segment_override = 120
        _state.edge_parallel_override = False
        if _state.edge_auto_tune_override is None:
            _state.edge_auto_tune_override = False
        if _state.chapter_stall_seconds is None:
            _state.chapter_stall_seconds = 60.0
        if not _state.edge_network_tier:
            _state.edge_network_tier = "slow"

    if _state.chapter_stall_seconds is not None:
        _runtime.os.environ["CHAPTER_STALL_SECONDS"] = str(_state.chapter_stall_seconds)
    if _state.edge_network_tier:
        _runtime.os.environ["EDGE_NETWORK_TIER"] = str(_state.edge_network_tier)

    if _state.clear_cache_flag:
        _runtime._append_event(_state.job, "🗑️ Clearing book cache before starting...")
        _runtime._clear_job_cache(_state.job)
    _runtime._append_event(_state.job, "📖 Analyzing ebook structure...")

    # **ASYNC OPTIMIZATION**: Run blocking I/O in thread pool
    _state.loop = _runtime.asyncio.get_event_loop()
    _state.reader = await _state.loop.run_in_executor(None, _runtime.EbookReader, str(_state.file_path))

    _runtime._update_job_activity(_state.job, stage="structure_analysis")
    _state.cover_blob = None
    _state.cached_cover_entry = None
    _state.file_hash = _state.job.get("fileHash")
    if _state.file_hash:
        _state.cached_cover_entry = _runtime.cover_cache_index.get(_state.file_hash)
    _state.cached_cover_path = None
    if _state.cached_cover_entry:
        _state.candidate = _runtime.cover_cache_dir / _state.cached_cover_entry.get("filename", "")
        if _state.candidate.exists():
            _state.cached_cover_path = _state.candidate

    if not _state.cached_cover_path:
        _state.cover_blob = await _state.loop.run_in_executor(None, _state.reader.extract_cover_image)

    _state.title = _state.reader.title or "Unknown_Book"
    _state.author = _state.reader.author or "Unknown Author"
    _state.job["bookTitle"] = _state.title
    _state.job["bookAuthor"] = _state.author

    _runtime._append_event(_state.job, f"📜 Title: {_state.title}")
    _runtime._append_event(_state.job, f"✍️ Author: {_state.author}")
    _state.job["chaptersCompleted"] = 0
    _state.verbose_enabled = True if _state.verbose_flag is None else bool(_state.verbose_flag)

    # Prepare chapters first to analyze language
    _runtime._append_event(_state.job, "📑 Extracting chapters from the book...")
    _runtime._update_job_activity(_state.job, stage="chapter_extraction")
    _state.converter_app = _runtime.ConverterApplication()
    _state.converter_app._interactive_mode = False
    try:
        _state.structure_items = await _state.loop.run_in_executor(
            None, _state.converter_app._generate_structure_items, _state.reader
        )
    except Exception:
        _state.structure_items = []
    _state.selector_text = " ".join(
        part for part in (_state.job.get("chapters"), _state.job.get("sections")) if part
    )
    _state.range_start = _state.job.get("fromChapterToEnd")
    _state.range_span = _state.job.get("fromChapterToChapter")
    _state.available_preview = ", ".join(str(item.index) for item in _state.structure_items[:10])

    if _state.structure_items:
        _state.range_end = None
        if _state.range_span:
            _state.parsed_range = _state.converter_app._parse_range_selector(_state.range_span)
            if _state.parsed_range:
                _state.range_start, _state.range_end = _state.parsed_range
            else:
                _state.range_start = None
        if _state.range_start:
            _state.structure_items, _state.filtered = _state.converter_app._filter_structure_range(
                _state.structure_items, _state.range_start, _state.range_end
            )
            if _state.filtered and not _state.structure_items:
                _state.selector_label = _state.range_span or _state.range_start
                _state.message = _state.converter_app.localization.t(
                    "selectors_not_found",
                    selectors=_state.selector_label,
                    available=_state.available_preview,
                )
                _runtime._append_event(_state.job, f"❌ {_state.message}")
                raise RuntimeError(_state.message)

        _state.selectors: list[str] = []
        if _state.job.get("chapters"):
            _state.selectors.extend(_state.converter_app._expand_selector_args([_state.job.get("chapters")]))
        if _state.job.get("sections"):
            _state.selectors.extend(_state.converter_app._expand_selector_args([_state.job.get("sections")]))
        if _state.selectors:
            _state.structure_items, _state.filtered = _state.converter_app._filter_structure_selection(
                _state.structure_items, _state.selectors
            )
            if _state.filtered and not _state.structure_items:
                _state.selector_preview = ", ".join(_state.selectors)
                _state.message = _state.converter_app.localization.t(
                    "selectors_not_found",
                    selectors=_state.selector_preview,
                    available=_state.available_preview,
                )
                _runtime._append_event(_state.job, f"❌ {_state.message}")
                raise RuntimeError(_state.message)

    # Detect language from book content
    _runtime._append_event(_state.job, "")
    _runtime._append_event(_state.job, "🌐 LANGUAGE DETECTION")
    _runtime._append_event(_state.job, "-" * 64)

    _state.language_profile: Optional[_runtime.LanguageProfile] = None
    _state.detected_lang = None
    _state._detection_fell_back = False
    _state.job_language = _state.job.get("language")
    _state.previously_detected = _state.job.get("detectedLanguage")
    _state.declared_language = getattr(_state.reader, "language", None)
    if _state.job_language and _state.job_language.lower() not in ("auto", ""):
        _state.detected_lang = _state.job_language
        _state.language_profile = _runtime.LanguageProfile(
            primary=_state.detected_lang,
            languages=[_state.detected_lang],
            predictions=[],
            analysed_chars=0,
        )
        _runtime._append_event(_state.job, f"🌐 User-selected language: {_state.detected_lang}")
    elif _state.declared_language and str(_state.declared_language).lower() not in {"auto", "unknown"}:
        _state.detected_lang = str(_state.declared_language)
        _state.language_profile = _runtime.LanguageProfile(
            primary=_state.detected_lang,
            languages=[_state.detected_lang],
            predictions=[],
            analysed_chars=0,
        )
        _runtime._append_event(_state.job, f"🌐 EPUB metadata language: {_state.detected_lang}")
    elif (
        _state.previously_detected
        and _state.job.get("resumeRequested")
        and not _state.job.get("_detectedLanguageFallback")
    ):
        # Re-use the language detected in the previous run to avoid re-detection
        # failure (e.g. [Errno 5] I/O error) from causing the resumed job to fail.
        # Only reuse if it was set by a successful detection, not a fallback default.
        _state.detected_lang = _state.previously_detected
        _state.language_profile = _runtime.LanguageProfile(
            primary=_state.detected_lang,
            languages=[_state.detected_lang],
            predictions=[],
            analysed_chars=0,
        )
        _runtime._append_event(_state.job, f"🌐 Resumed with cached language: {_state.detected_lang}")
    elif _state.structure_items:
        _runtime._append_event(_state.job, "🔍 Analyzing content to detect language...")
        _state._detection_fell_back = False
        try:
            _state.language_profile = await _runtime.asyncio.wait_for(
                _runtime.asyncio.to_thread(
                    _state.converter_app._prepare_language_profile,
                    _state.reader,
                    _state.structure_items,
                    _state.verbose_enabled,
                    allow_prompt=False,
                ),
                timeout=30.0,
            )
        except _runtime.asyncio.TimeoutError:
            _runtime._append_event(_state.job, "⚠️ Language detection timed out after 30s")
            _state.language_profile = None
        except Exception as exc:
            _state.exc = exc
            _runtime._append_event(_state.job, f"⚠️ Language detection error: {_state.exc}")
            _state.language_profile = None
        if _state.language_profile and _state.language_profile.primary:
            _state.detected_lang = _state.language_profile.primary
            if _state.language_profile.predictions:
                _state.confidence = _state.language_profile.predictions[0].probability
                _runtime._append_event(
                    _state.job,
                    f"🌐 Detected language: {_state.detected_lang} (confidence: {_state.confidence:.1%})",
                )
            else:
                _runtime._append_event(_state.job, f"🌐 Detected language: {_state.detected_lang}")
        else:
            _state.detected_lang = "pt-BR"
            _state._detection_fell_back = True
            _runtime._append_event(_state.job, f"🌐 Using default language: {_state.detected_lang}")
            _state.language_profile = _runtime.LanguageProfile(
                primary=_state.detected_lang,
                languages=[_state.detected_lang],
                predictions=[],
                analysed_chars=0,
            )
            # Mark as fallback so next resume re-runs detection instead of reusing
            _state.job["_detectedLanguageFallback"] = True
    else:
        _state._detection_fell_back = False
        _state.detected_lang = "pt-BR"
        _runtime._append_event(_state.job, f"🌐 Not enough text for detection, using: {_state.detected_lang}")
        _state.language_profile = _runtime.LanguageProfile(
            primary=_state.detected_lang,
            languages=[_state.detected_lang],
            predictions=[],
            analysed_chars=0,
        )

    _state.converter_app.language_profile = _state.language_profile
    _state.job["detectedLanguage"] = _state.detected_lang
    # Clear fallback flag when detection succeeded this run.
    # Also reset the voice if it was auto-set during a previous fallback run so the
    # engine can pick the correct voice for the newly detected language.
    if not _state._detection_fell_back:
        if _state.job.get("_voiceFromFallback"):
            _state.job.pop("voice", None)
            _state.job.pop("_voiceFromFallback", None)
            _runtime._append_event(_state.job, f"🔄 Voice reset for detected language: {_state.detected_lang}")
        _state.job.pop("_detectedLanguageFallback", None)
    _runtime._persist_job(_state.job_id, force=True)  # Persist metadata
    _runtime._update_job_activity(_state.job, stage="language_detected")

    # Create log callback to capture verbose TTS engine output
