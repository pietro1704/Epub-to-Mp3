# -*- coding: utf-8 -*-
"""Book conversion preparation."""

from __future__ import annotations

from typing import List

from .conversion_control import ConversionControl as _ConversionControl
from .ebook_reader import Chapter


async def _book_conversion_preparation(self, _state):
    from . import converter as _runtime
    """Convert all chapters in ``reader`` according to ``config``."""

    # Enable verbose mode if requested
    self.verbose = getattr(_state.config, "verbose", False)
    self._active_config = _state.config
    self._runtime_run_id = f"run-{_runtime.uuid.uuid4().hex[:16]}"
    self._runtime_profile_recorded_run_id = ""
    self._final_validation_passed = True
    self._startup_guardrail_applied = False
    self._canary_profile_done = False
    self._eta_recent_cps = []
    # Show TTS output only in verbose mode
    self.show_tts_output = self.verbose
    if not getattr(_state.config, "log_callback", None):
        # Roteia logs internos para a barra de progresso/CLI automaticamente
        def _log_to_progress(message: str) -> None:
            self.progress.tick(message)
            if not self.progress._supports_overwrite:
                print(message)
        _state._log_to_progress = _log_to_progress

        _state.config.log_callback = _state._log_to_progress

    # Initialize auto-tuning (detecta HW e network, configura flags automaticamente)
    await self._initialize_auto_tuning()

    # Initialize adaptive performance controller
    self._initialize_adaptive_performance()

    # Optimize memory and threading settings
    self._optimize_memory_settings()

    # Setup paths
    _state.reader_path = getattr(_state.reader, "file_path", None)
    try:
        self._current_book_path = _runtime.Path(_state.reader_path) if _state.reader_path else None
    except TypeError:
        self._current_book_path = None

    _state.output_dir = self._setup_output_directory(_state.config)
    self._last_output_dir = _state.output_dir

    # Honor --clear-cache: skip reading pre-existing cache and overwrite outputs.
    # Text files are overwritten via cleanup_existing=True in _generate_all_text_files.
    # Cached MP3s are ignored via ignore_cached_audio in _split_cached_chapters.
    # In-memory and on-disk chapter cache is bypassed via get_cached_chapters(bypass=True).
    # Best-effort deletion of stale artifacts (non-fatal if it fails).
    if getattr(_state.config, "clear_cache", False):
        if self.verbose:
            print("--clear-cache: bypassing pre-existing cache, outputs will be overwritten")
        try:
            if self._current_book_path:
                self.cache_manager.clear_cache(self._current_book_path, title=_state.reader.title)
            elif _state.reader.title:
                self.cache_manager.clear_cache(title=_state.reader.title)
        except Exception as exc:
            _state.exc = exc
            if self.verbose:
                print(f"Warning: could not remove cache directory: {_state.exc}")
    else:
        # Cache-first reruns must reach the cache splitter before the
        # expensive full-book validator. Final validation remains explicit.
        if self._should_run_initial_validation(_state.output_dir, _state.config):
            await self._auto_validate_output(_state.output_dir, stage="initial")
        elif self.verbose:
            print(
                "♻️ Existing audio detected; deferring initial validation until conversion completes"
            )

    # Duplicate cleanup can delete user files, so it is opt-in.
    _state.cleanup_duplicates = self._duplicate_cleanup_enabled(_state.config)
    if _state.cleanup_duplicates and self.verbose:
        print("🧹 Scanning for duplicate files to clean up...")

    _state.cleanup_count = 0
    if _state.cleanup_duplicates:
        # Clean output directory
        _state.cleanup_count = self._cleanup_duplicate_files(_state.output_dir, verbose=self.verbose)

        # Clean cache directory if exists
        if self._current_book_path and self.cache_manager.cache_dir:
            _state.cache_path = self.cache_manager._get_cache_path(self._current_book_path)
            if _state.cache_path.exists():
                _state.cleanup_count += self._cleanup_duplicate_files(_state.cache_path, verbose=False)

    if _state.cleanup_count > 0 and not self.verbose:
        print(f"🧹 Cleaned up {_state.cleanup_count} duplicate file(s)")

    # Setup temporary directory for conversion (uses .cache)
    _state.temp_dir = self._setup_temp_directory(_state.config)
    self._apply_runtime_feature_overrides(_state.config)
    self._apply_startup_guardrail(_state.config)
    self._load_adaptive_state_checkpoint(_state.temp_dir)
    _state.chapters = list(
        _state.reader.get_chapter_structure(preserve_all=_state.config.preserve_all_chapters) or []
    )
    _runtime.assign_chapter_identities(_state.chapters)
    # Store original before deduplication for potential restoration
    _state.original_chapters = _state.chapters.copy()

    _state.chapters, _state.duplicates_removed = _runtime.deduplicate_chapters_by_content(_state.chapters)
    if _state.duplicates_removed:
        print(f"  🧹 Removed {_state.duplicates_removed} duplicate chapter(s) automatically")

    if not _state.chapters:
        _state.empty_result = _runtime.ConversionResult(
            success=False,
            total_chapters=0,
            converted_chapters=0,
            output_files=[],
            errors=[f"No readable chapters were extracted from {_state.reader.title}"],
        )
        await self._report_results(_state.empty_result)
        return _ConversionControl("return", _state.empty_result)

    _state.chapter_stats = self._analyze_chapter_stats(_state.chapters)
    self._chapter_stats = _state.chapter_stats
    self._apply_chapter_engine_preferences(_state.config, _state.chapter_stats)

    # Validate chapter count against TOC (if available from CLI flow)
    _state.expected_count = getattr(_state.reader, "_toc_expected_chapters", 0)
    if _state.expected_count > 0 and len(_state.chapters) != _state.expected_count and _state.duplicates_removed > 0:
        if len(_state.chapters) + _state.duplicates_removed == _state.expected_count:
            print(
                f"\n⚠️  VALIDATION: TOC indicates {_state.expected_count} chapters, but {len(_state.chapters)} were detected"
            )
            print(
                f"🔄 Auto-correction: restoring {_state.duplicates_removed} chapter(s) removed as duplicate"
            )
            print("💡 Reason: deduplication caused loss of valid chapters\n")
            _state.chapters = _state.original_chapters

    _state.chapter_whitelist = self._parse_chapter_whitelist(_state.config)
    if _state.chapter_whitelist:
        _state.chapters = self._apply_chapter_whitelist(_state.chapters, _state.chapter_whitelist)
        if not _state.chapters:
            _state.empty_result = _runtime.ConversionResult(True, 0, 0, [], [])
            await self._report_results(_state.empty_result)
            return _ConversionControl("return", _state.empty_result)
    _state.resume_from_failure = True
    if getattr(_state.config, "extra", None):
        _state.resume_raw = _state.config.extra.get("resume_from_failure")
        if _state.resume_raw is not None:
            _state.resume_from_failure = str(_state.resume_raw).lower() in {"1", "true", "yes", "on"}
    if _state.resume_from_failure:
        _state.checkpoint = self._load_failure_checkpoint(_state.temp_dir)
        _state.failed_labels = (
            _state.checkpoint.get("failed_chapters", []) if isinstance(_state.checkpoint, dict) else []
        )
        if isinstance(_state.failed_labels, list) and _state.failed_labels:
            _state.failed_set = {str(item).strip() for item in _state.failed_labels if str(item).strip()}
            _state.resumed_chapters: List[Chapter] = []
            for _state.idx, _state.chapter in enumerate(_state.chapters, start=1):
                _state.chapter_num = self._chapter_number(_state.chapter, _state.idx)
                _state.chapter_label = self._chapter_display_name(_state.chapter, _state.chapter_num)
                _state.chapter_name = str(getattr(_state.chapter, "name", "") or "").strip()
                if (
                    str(_state.chapter_num) in _state.failed_set
                    or _state.chapter_label in _state.failed_set
                    or _state.chapter_name in _state.failed_set
                ):
                    _state.resumed_chapters.append(_state.chapter)
            if _state.resumed_chapters and len(_state.resumed_chapters) < len(_state.chapters):
                print(
                    f"🔁 Resume-from-failure: retrying only {len(_state.resumed_chapters)}/{len(_state.chapters)} failed chapter(s)"
                )
                _state.chapters = _state.resumed_chapters
        if isinstance(_state.checkpoint, dict):
            _state.blocked = _state.checkpoint.get("edge_blocked_chapters", [])
            if _state.blocked:
                if getattr(_state.config, "extra", None) is None:
                    _state.config.extra = {}
                _state.config.extra["edge_blocked_chapters"] = list(_state.blocked)

    # Set chapters_for_text AFTER filtering
    _state.chapters_for_text = _state.chapters
    self._last_chapters_for_text = list(_state.chapters_for_text)

    # ===== TEXT INTEGRITY VALIDATION =====
    # Validate text integrity BEFORE audio conversion to detect cache corruption
    _state.text_validator = _runtime.TextIntegrityValidator(cache_dir=_state.temp_dir, verbose=self.verbose)

    # Show chapter summary in verbose mode
    if self.verbose:
        _state.text_validator.print_chapter_summary(_state.chapters_for_text)

    # Refresh text cache before validation to avoid stale mismatches
    self._text_validation_hashes = {}
    self._text_validation_errors = []
    _state.initial_cleanup = bool(
        getattr(_state.config, "force_reprocess", False) or getattr(_state.config, "clear_cache", False)
    )
    self._generate_all_text_files(
        _state.chapters_for_text,
        _state.temp_dir,
        _state.config,
        cleanup_existing=_state.initial_cleanup,
        text_validator=_state.text_validator if getattr(_state.config, "validate_text", True) else None,
    )
    if self._text_validation_errors and self.verbose:
        print(
            f"⚠️ Post-parsing validation: {len(self._text_validation_errors)} problem(s) detected"
        )

    # Validate all chapters against cache
    _state.integrity_report = _state.text_validator.validate_all_chapters(
        _state.chapters_for_text, show_progress=True
    )

    # Hard-stop if chapters are empty or duplicated to avoid bad audio/output naming
    _state.hard_block_errors = [
        v
        for v in _state.integrity_report.chapters_with_issues
        if v.message and ("Chapter text empty" in v.message or "Duplicate content" in v.message)
    ]
    if _state.hard_block_errors:
        print("\n❌ Text validation failed: empty or duplicate chapters detected.")
        for _state.v in _state.hard_block_errors:
            print(f"   - Chapter {_state.v.chapter_index}: {_state.v.chapter_title} → {_state.v.message}")
        raise RuntimeError("Text validation failed: empty/duplicate chapters")

    # If cache corruption detected, offer to clear cache
    if _state.integrity_report.has_cache_corruption or _state.integrity_report.cache_engine_mismatch:
        print("\n⚠️  CORRUPTED CACHE DETECTED!")
        print(
            f"   {_state.integrity_report.invalid_chapters}/{_state.integrity_report.total_chapters} "
            "chapters have text different from current EPUB."
        )

        if _state.integrity_report.cache_engine_mismatch:
            print("\n💡 Possible cause: cache from previous conversion with different engine")
            print("   (e.g., Piper cache being used for Edge conversion)")

        # Auto-clear cache if corruption detected
        print("\n🧹 Cleaning corrupted cache automatically...")
        try:
            if self._current_book_path:
                self.cache_manager.clear_cache(self._current_book_path, title=_state.reader.title)
            elif _state.reader.title:
                self.cache_manager.clear_cache(title=_state.reader.title)

            # Recreate temp directory
            _state.temp_dir = self._setup_temp_directory(_state.config)
            self._apply_runtime_feature_overrides(_state.config)
            self._load_adaptive_state_checkpoint(_state.temp_dir)
            _state.text_validator = _runtime.TextIntegrityValidator(cache_dir=_state.temp_dir, verbose=self.verbose)

            self._generate_all_text_files(
                _state.chapters_for_text,
                _state.temp_dir,
                _state.config,
                cleanup_existing=True,
                text_validator=_state.text_validator
                if getattr(_state.config, "validate_text", True)
                else None,
            )

            print("✅ Cache cleaned! Proceeding with full conversion.\n")
        except Exception as exc:
            _state.exc = exc
            print(f"❌ Failure clearing cache: {_state.exc}")
            print("⚠️  Continuing with conversion but there may be issues.\n")

    # Save parsed text for all chapters (creates baseline for validation)
    _state.text_validator.save_all_chapters_text(_state.chapters_for_text, show_progress=not self.verbose)

    if getattr(_state.config, "priority_selectors", None):
        _state.chapters = self._prioritize_chapters(_state.chapters, _state.config.priority_selectors)
    _state.total_chapters = len(_state.chapters)
    # Init checkpoint tracking for this conversion run
    self._checkpoint_done_set = set()
    self._checkpoint_total = _state.total_chapters
    if self._current_book_path:
        _state._ckpt = self.cache_manager.load_checkpoint(self._current_book_path)
        if _state._ckpt and _state._ckpt.completed_chapters:
            self._checkpoint_done_set = set(_state._ckpt.completed_chapters)
            print(
                f"♻️  Checkpoint: {len(self._checkpoint_done_set)}/{_state._ckpt.total_chapters}"
                " chapters previously completed (skipping via cache detection)"
            )
