# -*- coding: utf-8 -*-
"""Book conversion completion."""

from __future__ import annotations

from .conversion_control import ConversionControl as _ConversionControl


async def _book_conversion_completion(self, _state):
    from . import converter as _runtime
    if _state.pending_failures:
        _state.ordered_errors = []
        for _state.name, _state.message in _state.pending_failures.items():
            _state.entry = self._lookup_chapter_entry(_state.chapter_lookup, _state.name)
            _state.idx = _state.entry[1] if _state.entry else _state.total_chapters + 1
            _state.ordered_errors.append((_state.idx, _state.name, _state.message))
        _state.ordered_errors.sort(key=lambda item: item[0])
        _state.result.errors = [
            f"{name}: {message} (attempts: {_state.attempts_used.get(name, 'n/d')})"
            if message
            else f"{name} (attempts: {_state.attempts_used.get(name, 'n/d')})"
            for _, name, message in _state.ordered_errors
        ]
    else:
        _state.result.errors = []

    if _state.unresolved_pool:
        for _state.name, _state.message in _state.unresolved_pool.items():
            _state.result.errors.append(f"{_state.name}: {_state.message} (uncorrelated)")

    # Reconcile: if an MP3 already exists in the output dir for a
    # "failed" chapter (e.g. hard timeout fired after synthesis completed
    # but during post-processing), drop it from the failure list.
    if _state.pending_failures or _state.unresolved_pool:
        _state.existing_mp3s = (
            {p.stem.lower() for p in _state.output_dir.glob("*.mp3")} if _state.output_dir.exists() else set()
        )
        _state.existing_mp3s |= {p.stem.lower() for p in _runtime.Path(_state.temp_dir).glob("*.mp3")}
        if _state.existing_mp3s:
            _state.resolved = [
                name
                for name in _state.pending_failures
                if any(name.lower() in mp3_stem for mp3_stem in _state.existing_mp3s)
            ]
            for _state.name in _state.resolved:
                _state.pending_failures.pop(_state.name, None)
            _state.resolved_unresolved = [
                name
                for name in _state.unresolved_pool
                if any(name.lower() in mp3_stem for mp3_stem in _state.existing_mp3s)
            ]
            for _state.name in _state.resolved_unresolved:
                _state.unresolved_pool.pop(_state.name, None)
            if _state.resolved or _state.resolved_unresolved:
                _state.result.converted_chapters += len(_state.resolved) + len(_state.resolved_unresolved)

    _state.result.success = not _state.pending_failures and not _state.unresolved_pool

    if _state.result.success:
        self._clear_failure_checkpoint(_state.temp_dir)
        # Clear conversion checkpoint — all chapters done, no need to resume
        if self._current_book_path:
            try:
                self.cache_manager.clear_checkpoint(self._current_book_path)
            except Exception:
                pass
    else:
        _state.edge_blocked = []
        if getattr(_state.config, "extra", None):
            _state.edge_blocked = _state.config.extra.get("edge_blocked_chapters", []) or []
        self._save_failure_checkpoint(
            _state.temp_dir,
            failed_chapters=_state.pending_failures.keys(),
            edge_blocked_chapters=_state.edge_blocked,
        )

    # Move successfully converted files even on partial failure (for resume capability)
    if _state.result.converted_chapters > 0:
        if self.verbose:
            print(f"[DEBUG] Moving {len(_state.result.output_files)} files to final directory...")

        _state.temp_mp3s = list(_runtime.Path(_state.temp_dir).glob("*.mp3"))
        _state.moved_files = self.file_manager.move_files_to_final_output(_state.temp_dir, _state.output_dir)

        # Only override output_files if we actually moved something
        if _state.moved_files:
            _state.result.output_files = _state.moved_files
            if _state.result.success:
                print(f"📁 {len(_state.moved_files)} files moved to: {_state.output_dir}")
            else:
                print(f"📁 {len(_state.moved_files)} converted chapters moved to: {_state.output_dir}")
                print("   💡 Run again to convert remaining chapters")
        _state.normalized_outputs = self._normalize_output_numbers(_state.chapters, _state.output_dir, _state.config)
        if _state.normalized_outputs:
            _state.result.output_files = _state.normalized_outputs

        # Apply ID3 tags (including cover art) to ALL MP3s in output dir,
        # not just newly converted ones — ensures partial/resumed conversions
        # always have consistent metadata and cover art.
        _state.album_name = _state.book_title or (
            self._current_book_path.stem if self._current_book_path else _state.output_dir.name
        )
        _state.all_output_mp3s = sorted(_state.output_dir.glob("*.mp3")) if _state.output_dir.exists() else []
        if _state.all_output_mp3s:
            self._apply_final_id3_tags(
                _state.all_output_mp3s,
                default_album=_state.album_name,
                artist=_state.book_author or None,
                cover_art=_state.cover_art,
            )

        # Clean temp audio only if we actually used temp files
        if _state.temp_mp3s:
            self._cleanup_temp_audio(_state.temp_dir)

    if not _state.result.success:
        if _state.result.converted_chapters > 0:
            print(f"⚠️ Partial conversion - {len(_state.pending_failures)} chapter(s) failed")
        else:
            print("❌ Conversion failed - no chapters converted")

    await self._stop_health_watchdog()
    self._sync_text_cache_to_output(_state.temp_dir, _state.output_dir)
    self.progress.finish()
    self._write_runtime_metrics_summary(_state.temp_dir)
    self._write_runtime_metrics_csv(_state.temp_dir)
    self._write_runtime_metrics_dashboard(_state.temp_dir)
    self._write_segment_metrics_summary(_state.temp_dir)
    self._write_segment_metrics_csv(_state.temp_dir)
    self._write_segment_metrics_dashboard(_state.temp_dir)
    self._write_runtime_recommendations(_state.temp_dir)
    await self._report_results(_state.result)
    return _ConversionControl("return", _state.result)
