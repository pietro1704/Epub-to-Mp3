# -*- coding: utf-8 -*-
"""Book failure recovery."""

from __future__ import annotations

from typing import Dict, List, Optional


async def _book_failure_recovery(self, _state):
    from . import converter as _runtime
    while _state.pending_failures and _state.retry_round <= _state.max_retry_rounds:
        _state.failed_names = list(_state.pending_failures.keys())
        _state.chapters_to_retry_info = []
        _state.missing_names = []
        for _state.name in _state.failed_names:
            _state.entry = self._lookup_chapter_entry(_state.chapter_lookup, _state.name)
            if _state.entry:
                _state.chapter_obj, _state.original_idx, _state.canonical_label = _state.entry
                _state.chapters_to_retry_info.append((_state.chapter_obj, _state.original_idx, _state.canonical_label))
                _state.attempts_used.setdefault(_state.canonical_label, 1)
            else:
                _state.missing_names.append(_state.name)

        for _state.missing in _state.missing_names:
            _state.message = _state.pending_failures.pop(_state.missing, "")
            _state.unresolved_pool[_state.missing] = _state.message or "Unknown reason"
            _state.attempts_used.pop(_state.missing, None)
            print(f"⚠️ Could not locate chapter for retry: {_state.missing}")

        if not _state.chapters_to_retry_info:
            break

        _state.rescue_profile: Optional[Dict[str, float]] = None
        if self._should_force_edge_rescue(
            _state.pending_failures,
            edge_available=_state.edge_available,
        ):
            if not _state.edge_rescue_applied:
                _state.rescue_profile = self._apply_edge_rescue_profile(
                    engine_pool=_state.engine_pool,
                    edge_configs=_state.edge_configs,
                    reason="failures detectadas em chapters longos",
                )
                _state.edge_rescue_applied = True
            elif not _state.edge_rescue_aggressive:
                _state.rescue_profile = self._apply_edge_rescue_profile(
                    engine_pool=_state.engine_pool,
                    edge_configs=_state.edge_configs,
                    reason="persistent failures even after safe adjustments",
                    aggressive=True,
                )
                _state.edge_rescue_aggressive = True

        for _state.chapter_obj, _state._original_idx, _state.canonical_label in _state.chapters_to_retry_info:
            _state.failure_message = _state.pending_failures.get(_state.canonical_label, "")
            if "Audio possibly truncated" in (_state.failure_message or ""):
                _state.attempts_so_far = _state.attempts_used.get(_state.canonical_label, 1)
                self._prepare_truncation_retry_payload(
                    _state.chapter_obj,
                    _state.canonical_label,
                    _state.attempts_so_far,
                    chapter_index=_state._original_idx,
                    output_dir=_state.temp_dir,
                    cache_dir=getattr(_state.config, "cache_dir", None),
                )

        _state.chapters_to_retry_info.sort(key=lambda item: item[1])
        _state.chapters_to_retry = [item[0] for item in _state.chapters_to_retry_info]

        if hasattr(self, "progress"):
            self.progress.tick(
                f"🔁 Automatic retry ({_state.retry_round}/{_state.max_retry_rounds}) for {len(_state.chapters_to_retry)} chapter(s)"
            )
        print(
            f"\n🔁 Retrying {len(_state.chapters_to_retry)} failed chapter(s) (attempt {_state.retry_round}/{_state.max_retry_rounds})"
        )
        _state.retry_config = _runtime.replace(_state.config, force_reprocess=True)
        _state.has_truncation = any(
            "Audio possibly truncated" in (_state.pending_failures.get(label) or "")
            for label in _state.pending_failures
        )
        if _state.rescue_profile:
            _state.retry_config = _runtime.replace(
                _state.retry_config,
                edge_chunk_chars=int(_state.rescue_profile["chunk_chars"]),
                edge_max_segment_seconds=int(_state.rescue_profile["max_segment"]),
                edge_auto_offline_chars=int(_state.rescue_profile["offline_chars"]),
                edge_auto_offline_seconds=int(_state.rescue_profile["offline_seconds"]),
                edge_enable_parallel=False,
                edge_max_concurrency=1,
            )
        elif _state.has_truncation and (_state.config.engine or "").lower() == "edge":
            _state.retry_config = _runtime.replace(
                _state.retry_config,
                edge_chunk_chars=4000,
                edge_max_segment_seconds=45,
                edge_enable_parallel=False,
                edge_max_concurrency=1,
            )
        if (_state.retry_config.engine or "").lower() == "edge":
            _state.base_chunk = int(_state.retry_config.edge_chunk_chars or _state.config.edge_chunk_chars or 4000)
            _state.base_seg = float(
                _state.retry_config.edge_max_segment_seconds or _state.config.edge_max_segment_seconds or 45
            )
            _state.chunk_factor = 0.75 ** max(1, _state.retry_round)
            _state.seg_factor = 0.85 ** max(1, _state.retry_round)
            _state.retry_config = _runtime.replace(
                _state.retry_config,
                edge_chunk_chars=max(1200, int(_state.base_chunk * _state.chunk_factor)),
                edge_max_segment_seconds=max(30, int(_state.base_seg * _state.seg_factor)),
                edge_enable_parallel=False,
                edge_max_concurrency=1,
            )
        _state.force_offline_engine: Optional[str] = None
        _state.retry_engine = (_state.retry_config.engine or "").lower()
        _state.force_offline_after_persistent_edge = (
            _state.edge_rescue_applied
            and not _state.forced_offline_once
            and _state.retry_round >= 2
            and _state.retry_engine == "edge"
        )
        if _state.force_offline_after_persistent_edge:
            _state.fallback_engine = self._resolve_offline_fallback_engine({"piper"})
            if _state.fallback_engine and _state.engine_pool.has_engine(_state.fallback_engine):
                _state.force_offline_engine = _state.fallback_engine
        if _state.force_offline_engine:
            _state.forced_offline_once = True
            _state.retry_config = _runtime.replace(_state.retry_config, engine=_state.force_offline_engine, voice=None)
            print(
                f"🛟 Edge unstable → forcing retry with {_state.force_offline_engine.upper()} (offline)"
            )
        _state.retry_result = await self._convert_chapters_sequential(
            _state.chapters_to_retry,
            _state.engine_pool,
            _state.temp_dir,
            _state.retry_config,
            is_auto_engine=_state.is_auto_engine,
            auto_engine_pool=_state.auto_engine_pool,
            book_title=_state.book_title,
            book_author=_state.book_author,
            cover_art=_state.cover_art,
        )

        _state.total_output_files.extend(_state.retry_result.output_files)
        _state.retry_error_map = self._build_error_map(_state.retry_result.errors)
        _state.normalised_retry, _state.unresolved_retry = self._normalise_failure_keys(
            _state.retry_error_map, _state.chapter_lookup
        )
        for _state.unresolved, _state.message in _state.unresolved_retry.items():
            print(f"⚠️ Returned failure without match: {_state.unresolved}")
            _state.unresolved_pool[_state.unresolved] = _state.message or "Unknown reason"

        for _state.chapter_obj, _state.original_idx, _state.canonical_label in _state.chapters_to_retry_info:
            _state.attempts_used[_state.canonical_label] = _state.attempts_used.get(_state.canonical_label, 1) + 1
            if _state.canonical_label in _state.normalised_retry:
                _state.pending_failures[_state.canonical_label] = _state.normalised_retry[_state.canonical_label]
            else:
                if _state.canonical_label in _state.pending_failures:
                    print(f"✅ Chapter recovered: {_state.canonical_label}")
                _state.pending_failures.pop(_state.canonical_label, None)

        _state.retry_round += 1

    # Final rescue: switch engine for remaining failures (auto mode only)
    if _state.pending_failures and _state.is_auto_engine and _state.auto_engine_pool:
        _state.rescue_engine = None
        if "piper" in _state.auto_engine_pool:
            _state.rescue_engine = "piper"
        if _state.rescue_engine:
            _state.failed_names = list(_state.pending_failures.keys())
            _state.chapters_to_retry_info = []
            for _state.name in _state.failed_names:
                _state.entry = self._lookup_chapter_entry(_state.chapter_lookup, _state.name)
                if _state.entry:
                    _state.chapter_obj, _state.original_idx, _state.canonical_label = _state.entry
                    _state.chapters_to_retry_info.append((_state.chapter_obj, _state.original_idx, _state.canonical_label))
                    _state.attempts_used.setdefault(_state.canonical_label, 1)
            _state.chapters_to_retry_info.sort(key=lambda item: item[1])
            _state.chapters_to_retry = [item[0] for item in _state.chapters_to_retry_info]
            if _state.chapters_to_retry:
                print(
                    f"\n🛟 Final rescue: reprocessing {len(_state.chapters_to_retry)} chapter(s) with {_state.rescue_engine.upper()}"
                )
                _state.rescue_config = _runtime.replace(
                    _state.config,
                    engine=_state.rescue_engine,
                    voice=None,
                    force_reprocess=True,
                    edge_enable_parallel=False,
                )
                _state.rescue_config.extra = dict(_state.rescue_config.extra or {})
                _state.rescue_result = await self._convert_chapters_sequential(
                    _state.chapters_to_retry,
                    _state.engine_pool,
                    _state.temp_dir,
                    _state.rescue_config,
                    is_auto_engine=_state.is_auto_engine,
                    auto_engine_pool=_state.auto_engine_pool,
                    book_title=_state.book_title,
                    book_author=_state.book_author,
                    cover_art=_state.cover_art,
                )
                _state.total_output_files.extend(_state.rescue_result.output_files)
                _state.retry_error_map = self._build_error_map(_state.rescue_result.errors)
                _state.normalised_retry, _state.unresolved_retry = self._normalise_failure_keys(
                    _state.retry_error_map, _state.chapter_lookup
                )
                for _state.unresolved, _state.message in _state.unresolved_retry.items():
                    _state.unresolved_pool[_state.unresolved] = _state.message or "Unknown reason"
                _state.pending_failures = _state.normalised_retry

    if _state.pending_failures and _state.manual_retry_requested:
        _state.failed_names = list(_state.pending_failures.keys())
        _state.chapters_to_retry_info = []
        for _state.name in _state.failed_names:
            _state.entry = self._lookup_chapter_entry(_state.chapter_lookup, _state.name)
            if _state.entry:
                _state.chapter_obj, _state.original_idx, _state.canonical_label = _state.entry
                _state.chapters_to_retry_info.append((_state.chapter_obj, _state.original_idx, _state.canonical_label))
                _state.attempts_used.setdefault(_state.canonical_label, 1)
        _state.chapters_to_retry_info.sort(key=lambda item: item[1])
        _state.chapters_to_retry = [item[0] for item in _state.chapters_to_retry_info]
        if _state.chapters_to_retry:
            print(
                f"\n🔁 Manual retry requested: reprocessing {len(_state.chapters_to_retry)} chapter(s)"
            )
            _state.manual_config = _runtime.replace(_state.config, force_reprocess=True)
            _state.manual_config.extra = dict(_state.manual_config.extra or {})
            _state.manual_config.extra.pop("manual_retry_failed", None)
            _state.manual_result = await self._convert_chapters_sequential(
                _state.chapters_to_retry,
                _state.engine_pool,
                _state.temp_dir,
                _state.manual_config,
                is_auto_engine=_state.is_auto_engine,
                auto_engine_pool=_state.auto_engine_pool,
                book_title=_state.book_title,
                book_author=_state.book_author,
                cover_art=_state.cover_art,
            )
            _state.total_output_files.extend(_state.manual_result.output_files)
            _state.retry_error_map = self._build_error_map(_state.manual_result.errors)
            _state.normalised_retry, _state.unresolved_retry = self._normalise_failure_keys(
                _state.retry_error_map, _state.chapter_lookup
            )
            for _state.unresolved, _state.message in _state.unresolved_retry.items():
                _state.unresolved_pool[_state.unresolved] = _state.message or "Unknown reason"
            _state.pending_failures = _state.normalised_retry
        else:
            print("ℹ️ Manual retry requested, but no remaining chapters to reprocess.")

    if _state.pending_failures:
        print(f"\n⚠️ Some chapters still failed after {_state.max_retry_rounds} attempt(s).")
        if hasattr(self, "progress"):
            self.progress.tick("❌ Incomplete conversion - pending chapters after retries")
    elif _state.attempts_used and any(attempts > 1 for attempts in _state.attempts_used.values()):
        print("\n✅ All chapters were successfully converted after additional attempts.")

    _state.unique_outputs: List[_runtime.Path] = []
    _state.seen_outputs = set()
    for _state.path in _state.total_output_files:
        _state.key = str(_state.path)
        if _state.key in _state.seen_outputs:
            continue
        _state.seen_outputs.add(_state.key)
        _state.unique_outputs.append(_state.path)

    _state.result.output_files = _state.unique_outputs
    _state.converted_estimate = len(_state.unique_outputs)
    if not _state.pending_failures:
        _state.converted_estimate = max(_state.converted_estimate, _state.total_chapters)
    else:
        _state.converted_estimate = max(_state.converted_estimate, _state.total_chapters - len(_state.pending_failures))
    _state.result.converted_chapters = _state.converted_estimate
    _state.result.total_chapters = _state.total_chapters
