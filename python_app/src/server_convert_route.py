# -*- coding: utf-8 -*-
"""Conversion upload request normalization and scheduling."""

from __future__ import annotations

from typing import Optional

from fastapi import BackgroundTasks, File, Form, UploadFile


async def convert_ebook(_runtime,
    background_tasks: BackgroundTasks,
    file: UploadFile | None = File(None),
    upload_id: Optional[str] = Form(None),
    engine: str = Form("edge"),
    voice: Optional[str] = Form(None),
    model: Optional[str] = Form(None),
    chapters: Optional[str] = Form(None),
    sections: Optional[str] = Form(None),
    fromChapterToEnd: Optional[str] = Form(None),
    fromChapterToChapter: Optional[str] = Form(None),
    footnote_mode: Optional[str] = Form("inline"),
    language: Optional[str] = Form(None),
    priority: Optional[str] = Form(None),
    formatting_cues: Optional[str] = Form("on"),
    no_parallel: Optional[str] = Form(None),
    multi_engine_parallel: Optional[str] = Form(None),
    parallel_slots: Optional[str] = Form(None),
    max_performance: Optional[str] = Form(None),
    chapter_stall_seconds: Optional[str] = Form(None),
    edge_network_tier: Optional[str] = Form(None),
    edge_chunk_chars: Optional[str] = Form(None),
    edge_max_segment_seconds: Optional[str] = Form(None),
    edge_enable_parallel: Optional[str] = Form(None),
    edge_auto_tune: Optional[str] = Form(None),
    edge_stable_mode: Optional[str] = Form(None),
    piper_max_procs: Optional[str] = Form(None),
    engine_chain_fallback: Optional[str] = Form(None),
    bitrate: Optional[str] = Form(None),
    sample_rate: Optional[str] = Form(None),
    channels: Optional[str] = Form(None),
    clear_cache: Optional[str] = Form(None),
    force_reprocess: Optional[str] = Form(None),
    filter_chapters: Optional[str] = Form(None),
    verbose: Optional[str] = Form(None),
    use_language_detection: Optional[str] = Form(None),
    prioritize_primary_language: Optional[str] = Form(None),
    health_check_interval_seconds: Optional[str] = Form(None),
    health_check_slow_edge_cps: Optional[str] = Form(None),
    health_check_slow_cps: Optional[str] = Form(None),
    health_check_high_cpu: Optional[str] = Form(None),
    health_check_high_mem: Optional[str] = Form(None),
    health_check_ok_cpu: Optional[str] = Form(None),
    health_check_ok_mem: Optional[str] = Form(None),
    health_check_slow_streak: Optional[str] = Form(None),
    ui_language: Optional[str] = Form(None),
    enable_character_voices: Optional[str] = Form(None),
    narrator_voice: Optional[str] = Form(None),
    character_voice: Optional[str] = Form(None),
    export_to_iphone: Optional[str] = Form(None),
    priority_chapter_index: Optional[str] = Form(None),
) -> dict[str, str]:
    enable_character_voices_flag = _runtime._parse_form_optional_bool(enable_character_voices)
    narrator_voice_value = (narrator_voice or "").strip() or None
    character_voice_value = (character_voice or "").strip() or None
    export_to_iphone_flag = _runtime._parse_form_optional_bool(export_to_iphone)
    speak_cues = _runtime._parse_form_bool(formatting_cues, True)
    ui_lang = _runtime._normalize_locale(ui_language, "pt")
    disable_parallel = _runtime._parse_form_bool(no_parallel, False)
    multi_engine_parallel_flag = _runtime._parse_form_bool(multi_engine_parallel, False)
    max_performance_enabled = _runtime._parse_form_bool(max_performance, False)
    parallel_slots_override = _runtime._parse_form_int(
        parallel_slots,
        min_value=1,
        max_value=_runtime._CHAPTER_PARALLEL_MAX,
    )
    chapter_stall_override = _runtime._parse_form_float(
        chapter_stall_seconds,
        min_value=10.0,
        max_value=900.0,
    )
    edge_network_tier_override = None
    if edge_network_tier:
        normalized = edge_network_tier.strip().lower()
        if normalized in {"slow", "medium", "fast", "ultra"}:
            edge_network_tier_override = normalized
    edge_chunk_override = _runtime._parse_form_int(edge_chunk_chars, min_value=4000, max_value=24000)
    edge_segment_override = _runtime._parse_form_int(edge_max_segment_seconds, min_value=30, max_value=600)
    edge_parallel_override = _runtime._parse_form_optional_bool(edge_enable_parallel)
    edge_auto_tune_override = _runtime._parse_form_optional_bool(edge_auto_tune)
    edge_stable_mode_flag = _runtime._parse_form_optional_bool(edge_stable_mode)
    piper_procs_override = _runtime._parse_form_int(piper_max_procs, min_value=1, max_value=12)
    engine_chain_fallback_flag = _runtime._parse_form_optional_bool(engine_chain_fallback)
    sample_rate_override = _runtime._parse_form_int(sample_rate, min_value=8000, max_value=96000)
    channels_override = _runtime._parse_form_int(channels, min_value=1, max_value=2)
    clear_cache_flag = _runtime._parse_form_bool(clear_cache, False)
    force_reprocess_flag = _runtime._parse_form_bool(force_reprocess, False)
    priority_chapter_index_value = _runtime._parse_form_int(priority_chapter_index, min_value=0)
    filter_chapters_flag = _runtime._parse_form_bool(filter_chapters, False)
    verbose_flag = _runtime._parse_form_optional_bool(verbose)
    use_language_detection_flag = _runtime._parse_form_optional_bool(use_language_detection)
    prioritize_primary_flag = _runtime._parse_form_optional_bool(prioritize_primary_language)
    health_check_interval_override = _runtime._parse_form_float(
        health_check_interval_seconds,
        min_value=10.0,
        max_value=300.0,
    )
    health_check_slow_edge_override = _runtime._parse_form_float(
        health_check_slow_edge_cps,
        min_value=10.0,
        max_value=500.0,
    )
    health_check_slow_override = _runtime._parse_form_float(
        health_check_slow_cps,
        min_value=10.0,
        max_value=300.0,
    )
    health_check_high_cpu_override = _runtime._parse_form_float(
        health_check_high_cpu,
        min_value=30.0,
        max_value=100.0,
    )
    health_check_high_mem_override = _runtime._parse_form_float(
        health_check_high_mem,
        min_value=30.0,
        max_value=100.0,
    )
    health_check_ok_cpu_override = _runtime._parse_form_float(
        health_check_ok_cpu,
        min_value=10.0,
        max_value=100.0,
    )
    health_check_ok_mem_override = _runtime._parse_form_float(
        health_check_ok_mem,
        min_value=10.0,
        max_value=100.0,
    )
    health_check_slow_streak_override = _runtime._parse_form_int(
        health_check_slow_streak,
        min_value=1,
        max_value=6,
    )
    from_chapter_to_end = (fromChapterToEnd or "").strip() or None
    from_chapter_to_chapter = (fromChapterToChapter or "").strip() or None
    if from_chapter_to_end and from_chapter_to_chapter:
        raise _runtime.HTTPException(
            status_code=400,
            detail="Use apenas fromChapterToEnd ou fromChapterToChapter.",
        )
    if from_chapter_to_chapter:
        parsed_range = _runtime.ConverterApplication._parse_range_selector(from_chapter_to_chapter)
        if not parsed_range:
            raise _runtime.HTTPException(
                status_code=400,
                detail="Invalid range. Use A..B (e.g. 5.1..7.3).",
            )
    reuse_upload = None
    job_input_dir = None
    book_title: Optional[str] = None
    book_author: Optional[str] = None
    if upload_id:
        with _runtime._pending_lock:
            reuse_upload = _runtime._pending_uploads.pop(upload_id, None)
        if not reuse_upload:
            reuse_upload = _runtime._load_pending_upload_from_disk(upload_id)
            if not reuse_upload:
                raise _runtime.HTTPException(status_code=404, detail="Upload not found or expired")
        job_id = str(_runtime.uuid.uuid4())
        job_input_dir = _runtime._resolve_relative_path_within_root(_runtime.job_inputs_dir, job_id, must_exist=False)
        job_input_dir.mkdir(parents=True, exist_ok=True)
        upload_root = _runtime._resolve_relative_path_within_root(_runtime.uploads_dir, upload_id, must_exist=True)
        try:
            source_file = _runtime._resolve_path_within_root(
                upload_root, reuse_upload["file_path"], must_exist=True
            )
        except ValueError:
            raise _runtime.HTTPException(status_code=400, detail="Invalid uploaded source file")
        file_hash = reuse_upload.get("file_hash")
        cover_name = reuse_upload.get("cover_filename")
        cover_mime = reuse_upload.get("cover_mime")
        cover_url = None
        original_name = _runtime._safe_leaf_name(
            reuse_upload.get("file_name") or source_file.name, field_name="file name"
        )
        temp_file = _runtime._resolve_relative_path_within_root(
            job_input_dir, original_name, must_exist=False
        )
        _runtime.shutil.move(str(source_file), temp_file)
        book_title = reuse_upload.get("book_title")
        book_author = reuse_upload.get("book_author")
        if cover_name:
            try:
                cover_source = _runtime._resolve_path_within_root(
                    upload_root, reuse_upload.get("cover_path") or "", must_exist=True
                )
            except ValueError:
                cover_source = None
            if cover_source and cover_source.exists():
                temp_job = {"bookTitle": book_title, "engine": engine}
                safe_cover_name = _runtime._safe_leaf_name(cover_name, field_name="cover name")
                dest_cover = _runtime._resolve_relative_path_within_root(
                    _runtime._job_output_dir(job_id, temp_job, ensure=True),
                    safe_cover_name,
                    must_exist=False,
                )
                _runtime.shutil.move(str(cover_source), dest_cover)
                cover_url = f"/api/outputs/{job_id}/{safe_cover_name}"
        upload_folder = source_file.parent
        if upload_folder.exists() and upload_folder.is_relative_to(upload_root):
            _runtime.shutil.rmtree(upload_folder, ignore_errors=True)
    else:
        if file is None:
            raise _runtime.HTTPException(status_code=400, detail="No file uploaded")
        job_id = f"{_runtime.uuid.uuid4()}"
        job_input_dir = _runtime._resolve_relative_path_within_root(_runtime.job_inputs_dir, job_id, must_exist=False)
        job_input_dir.mkdir(parents=True, exist_ok=True)
        temp_file = _runtime._resolve_relative_path_within_root(
            job_input_dir,
            _runtime.Path(file.filename or "ebook.epub").name,
            must_exist=False,
        )
        from src.upload_streaming import UploadTooLarge, stream_upload_to_path

        try:
            file_hash, _ = await stream_upload_to_path(file, temp_file, max_bytes=_runtime.MAX_UPLOAD_BYTES)
        except UploadTooLarge:
            _runtime.shutil.rmtree(job_input_dir, ignore_errors=True)
            raise _runtime.HTTPException(
                status_code=413,
                detail=f"File exceeds the {_runtime.MAX_UPLOAD_MB} MB limit",
            )

        cover_name = None
        cover_url = None
        cover_mime = None
        cover_blob = None
        try:
            reader_for_cover = _runtime.EbookReader(str(temp_file))
            cover_blob = reader_for_cover.extract_cover_image()
            if not book_title:
                book_title = reader_for_cover.title
            if not book_author:
                book_author = reader_for_cover.author
            if cover_blob:
                cover_slug = (
                    _runtime.FileManager.sanitize_filename(
                        reader_for_cover.title or _runtime.Path(file.filename).stem
                    )
                    or "capa"
                )
                filename = f"{cover_slug}_cover{cover_blob.extension}"
                temp_job = {
                    "bookTitle": book_title or reader_for_cover.title or _runtime.Path(file.filename).stem,
                    "engine": engine,
                }
                cover_path = _runtime._job_output_dir(job_id, temp_job, ensure=True)
                safe_filename = _runtime.Path(filename).name
                target = _runtime._resolve_relative_path_within_root(
                    cover_path, safe_filename, must_exist=False
                )
                target.write_bytes(cover_blob.data)
                cover_name = safe_filename
                cover_url = f"/api/outputs/{job_id}/{safe_filename}"
                cover_mime = cover_blob.media_type
        except Exception:
            pass

    book_title = book_title or (reuse_upload.get("book_title") if reuse_upload else None)
    if not book_title:
        book_title = _runtime.Path(temp_file.name).stem
    book_author = book_author or (reuse_upload.get("book_author") if reuse_upload else None)
    book_slug = _runtime._book_slug(book_title, temp_file.name)
    output_book_dir = _runtime._resolve_relative_path_within_root(_runtime.output_dir, book_slug, must_exist=False)
    output_book_dir.mkdir(parents=True, exist_ok=True)
    cache_base = _runtime._resolve_relative_path_within_root(_runtime.CACHE_DIR, book_slug, must_exist=False)
    cache_base.mkdir(parents=True, exist_ok=True)

    parallel_slots_value = parallel_slots_override
    if not disable_parallel and max_performance_enabled and parallel_slots_value is None:
        parallel_slots_value = _runtime._CHAPTER_PARALLEL_MAX
    if disable_parallel:
        parallel_slots_value = 1
    if parallel_slots_value is None:
        parallel_slots_value = _runtime.recommend_parallel_slots(engine, _runtime._PARALLEL_SLOTS_DEFAULT)

    _runtime.jobs[job_id] = {
        "jobId": job_id,
        "state": "queued",
        "events": [],
        "_raw_log": [],
        "file_path": str(temp_file),
        "engine": engine,
        "voice": voice,
        "model": model,
        "chapters": chapters,
        "sections": sections,
        "fromChapterToEnd": from_chapter_to_end,
        "fromChapterToChapter": from_chapter_to_chapter,
        "footnote_mode": footnote_mode,
        "language": language,
        "priority": priority,
        "priorityChapterIndex": priority_chapter_index_value,
        "formattingCues": speak_cues,
        "uiLanguage": ui_lang,
        "outputs": [],
        "bookTitle": book_title,
        "bookAuthor": book_author,
        "outputDir": str(output_book_dir),
        "cacheDir": str(cache_base),
        "cover": {"name": cover_name, "url": cover_url, "mimeType": cover_mime}
        if cover_name
        else None,
        "coverUrl": cover_url,
        "coverMimeType": cover_mime,
        "cancelRequested": False,
        "fileHash": file_hash,
        "parallelSlots": parallel_slots_value,
        "parallelSlotsRequested": parallel_slots_override,
        "parallelActive": 0,
        "noParallel": disable_parallel,
        "multiEngineParallel": multi_engine_parallel_flag,
        "maxPerformance": max_performance_enabled,
        "chapterStallSeconds": chapter_stall_override,
        "edgeNetworkTier": edge_network_tier_override,
        "edgeChunkChars": edge_chunk_override,
        "edgeMaxSegmentSeconds": edge_segment_override,
        "edgeEnableParallel": edge_parallel_override,
        "edgeAutoTune": edge_auto_tune_override,
        "edgeStableMode": edge_stable_mode_flag,
        "piperMaxProcs": piper_procs_override,
        "engineChainFallback": engine_chain_fallback_flag,
        # Multi-voice narration (default on; UI may override per-job).
        "enableCharacterVoices": (
            True if enable_character_voices_flag is None else bool(enable_character_voices_flag)
        ),
        "narratorVoice": narrator_voice_value,
        "characterVoice": character_voice_value,
        # iPhone export (v0.3.20): explicit opt-in per job. macOS-only;
        # job runner respects EXPORT_TO_IPHONE env as a fallback.
        "exportToIphone": (False if export_to_iphone_flag is None else bool(export_to_iphone_flag)),
        "bitrate": bitrate,
        "sampleRate": sample_rate_override,
        "channels": channels_override,
        "clearCache": clear_cache_flag,
        "forceReprocess": force_reprocess_flag,
        "filterChapters": filter_chapters_flag,
        "verbose": verbose_flag,
        "useLanguageDetection": use_language_detection_flag,
        "prioritizePrimaryLanguage": prioritize_primary_flag,
        "healthCheckIntervalSeconds": health_check_interval_override,
        "healthCheckSlowEdgeCps": health_check_slow_edge_override,
        "healthCheckSlowCps": health_check_slow_override,
        "healthCheckHighCpu": health_check_high_cpu_override,
        "healthCheckHighMem": health_check_high_mem_override,
        "healthCheckOkCpu": health_check_ok_cpu_override,
        "healthCheckOkMem": health_check_ok_mem_override,
        "healthCheckSlowStreak": health_check_slow_streak_override,
        "resumeRequested": False,
        "uploadDir": str(job_input_dir) if job_input_dir else None,
        "createdAt": _runtime._utcnow_iso(),
        "progressPercent": 0.0,
        "chaptersCompleted": 0,
        "chaptersTotal": 0,
    }
    _runtime._update_job_activity(_runtime.jobs[job_id], stage="queued")
    _runtime._append_event(_runtime.jobs[job_id], "📚 File received, waiting for processing...")

    # Persist job state to disk IMMEDIATELY before returning
    save_success = _runtime.job_manager.save_job(job_id, _runtime.jobs[job_id])
    if not save_success:
        _runtime.logger.error(f"Failed to save job {job_id} on creation!")
        # Still continue - job is in memory
    else:
        _runtime.logger.info(f"Job {job_id} created and persisted successfully")

    if not _runtime._enqueue_job(job_id):
        background_tasks.add_task(_runtime._schedule_job_conversion, job_id)
    return {"jobId": job_id}
