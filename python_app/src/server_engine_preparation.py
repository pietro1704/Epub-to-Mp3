# -*- coding: utf-8 -*-
"""Server engine preparation."""

from __future__ import annotations

from typing import Dict, Optional

from .conversion_control import ConversionControl as _ConversionControl
from .engine_pool import ResourceSnapshot


async def _server_engine_preparation(_runtime, _state):

    def _update_estimated_chapter_progress(chapter_index: int, ratio: float) -> None:
        _runtime._update_job_activity(_state.job)
        _runtime.update_estimated_chapter_progress(_state.job, chapter_index, ratio, len(_state.chapters))
    _state._update_estimated_chapter_progress = _update_estimated_chapter_progress

    def _refresh_chapter_completion() -> None:
        _runtime.refresh_chapter_completion(_state.job)
    _state._refresh_chapter_completion = _refresh_chapter_completion

    def _count_completed_chapters() -> int:
        return _runtime.count_completed_chapters(_state.job)
    _state._count_completed_chapters = _count_completed_chapters

    _state.chapter_progress_entries: list[dict] = []
    for _state.idx, _state.chapter in enumerate(_state.chapters, 1):
        _state.chapter_name = _runtime._chapter_display_name(
            getattr(_state.chapter, "name", None),
            getattr(_state.chapter, "raw_html", None),
            _state.idx,
        )
        _state.chapter_text = (
            getattr(_state.chapter, "speech_text", None) or getattr(_state.chapter, "text", "") or ""
        )
        _state.entry: dict = {
            "index": _state.idx,
            "name": _state.chapter_name,
            "status": "pending",
        }
        _state.ch_chars = _state.chapter_char_totals.get(_state.idx)
        if _state.ch_chars:
            _state.entry["chars"] = _state.ch_chars
        _state.word_count = _runtime.count_words(_state.chapter_text)
        if _state.word_count > 0:
            _state.entry["wordCount"] = _state.word_count
        _state.chapter_progress_entries.append(_state.entry)
    _state.job["chapterProgress"] = _state.chapter_progress_entries
    _state._refresh_chapter_completion()

    # Pre-flight language verification (mirror of CLI guard from
    # main.py:_preflight_language_and_config_check). The user's
    # explicit language choice (web form `language` field other
    # than "auto") wins; otherwise mismatch aborts before TTS.
    _state._user_language_override = bool(
        (_state.config.extra or {}).get("user_language_override")
        or (
            _state.config.primary_language
            and _state.config.primary_language.lower() != "auto"
            and not (_state.config.extra or {}).get("language_auto_detected")
        )
    )
    _state._preflight_error = _runtime.preflight_language_check(
        _state.chapters, _state.config, user_language_override=_state._user_language_override
    )
    if _state._preflight_error:
        _runtime._append_event(_state.job, f"❌ {_state._preflight_error}")
        _state.job["state"] = "error"
        _state.job["error"] = _state._preflight_error
        _runtime._persist_job(_state.job_id, force=True)
        return _ConversionControl("return", None)

    # Reuse existing output when ≥90% of expected MP3s are already
    # on disk (mirror of CLI `_detect_reusable_existing_output`).
    # `--clear-cache` / force is signalled by the web form via
    # `force_resynth` in the extra dict.
    _state._force_resynth = bool((_state.config.extra or {}).get("force_resynth"))
    try:
        _state._expected_output_dir = _runtime.Path(
            getattr(_state.config, "output_dir", None) or _runtime.OUTPUT_DIR
        ) / _runtime.FileManager.sanitize_filename(getattr(_state.config, "book_title", "") or "default")
    except Exception:
        _state._expected_output_dir = None
    if _state._expected_output_dir is not None:
        _state._reusable = _runtime.detect_reusable_existing_output(
            _state._expected_output_dir, len(_state.chapters), force=_state._force_resynth
        )
        if _state._reusable is not None:
            _runtime._append_event(
                _state.job,
                f"♻️ Reusing existing output ({len(list(_state._reusable.glob('*.mp3')))} MP3s in {_state._reusable}); skipping synthesis",
            )

    _state.engine_chain = _runtime._build_engine_chain(_state.config)
    _state.engine_index = 0
    _state.active_config: Optional[_runtime.ConversionConfig] = None
    _state.auto_mode = (_state.config.engine or "").lower() == "auto"
    _state.slot_affinity: list[str] = []  # populated after parallel_slots is known
    _state._multi_engine_requested = bool(_state.config.extra.get("multi_engine_parallel"))

    _state.auto_engine_pool: dict[str, _runtime.ConversionConfig] = {}
    _state.telemetry_speeds: Dict[str, object] = {}
    _state.preferred_auto_engine: Optional[str] = None
    _state.engine_seeds: dict[str, object] = {}
    _state.unavailable_engines: set[str] = set()
    _state.auto_tuning_summary: dict[str, dict[str, object]] = {}
    _state.auto_edge_profile: Optional[dict[str, object]] = None
    _state.edge_network_tier = (
        (getattr(_runtime._hardware_profile, "network_speed_estimate", "fast") or "fast").strip().lower()
    )

    if not _state.auto_mode:
        _runtime._append_event(_state.job, "")
        _runtime._append_event(_state.job, f"🔧 Initializing TTS engine ({_state.config.engine})...")
        while _state.engine_index < len(_state.engine_chain):
            _state.candidate = _state.engine_chain[_state.engine_index]
            _state.engine_name = (_state.candidate.engine or "").lower()
            _runtime._set_engine_status(_state.job, _state.engine_name, "loading", "Loading model...")
            try:
                _state.engine_obj = _runtime.tts_factory.create_engine(_state.candidate)
                _state.active_config = _state.candidate
                if _state.engine_name:
                    _state.engine_seeds[_state.engine_name] = _state.engine_obj
                _runtime._set_engine_status(_state.job, _state.engine_name, "ready", "Ready")
                _runtime._append_event(_state.job, f"✅ Engine {_state.candidate.engine} ready")
                break
            except ImportError as exc:
                _state.exc = exc
                _runtime._set_engine_status(_state.job, _state.engine_name, "error", str(_state.exc))
                _runtime._append_event(_state.job, f"⚠️ Engine unavailable: {_state.exc}")
            except Exception as exc:
                _state.exc = exc
                _runtime._set_engine_status(_state.job, _state.engine_name, "error", str(_state.exc))
                _runtime._append_event(_state.job, f"⚠️ Failed to initialize engine '{_state.candidate.engine}': {_state.exc}")
            _state.engine_index += 1

        if not _state.engine_seeds or _state.active_config is None:
            _state.job["state"] = "failed"
            _state.no_engine_message = (
                "No TTS engine available. Install a compatible voice model in Settings "
                "or enable Edge-TTS."
            )
            _runtime._set_job_error(_state.job, _state.no_engine_message)
            _runtime._append_event(_state.job, f"❌ {_state.no_engine_message}")
            _runtime._persist_job(_state.job_id, force=True)
            return _ConversionControl("return", None)

        # Pre-load secondary engines for multi-engine parallel slots.
        if _state._multi_engine_requested:
            for _state.extra_candidate in _state.engine_chain[_state.engine_index + 1 :]:
                _state.extra_name = (_state.extra_candidate.engine or "").lower()
                if not _state.extra_name or _state.extra_name in _state.engine_seeds:
                    continue
                try:
                    _state.extra_obj = _runtime.tts_factory.create_engine(_state.extra_candidate)
                    _state.engine_seeds[_state.extra_name] = _state.extra_obj
                    _runtime._set_engine_status(_state.job, _state.extra_name, "ready", "Ready (secondary)")
                    _runtime._append_event(_state.job, f"✅ Pre-loaded {_state.extra_name} for multi-engine parallel")
                except Exception as exc:
                    _state.exc = exc
                    _runtime._append_event(_state.job, f"⚠️ Could not pre-load {_state.extra_name}: {_state.exc}")
    else:
        _state.active_config = _state.config
        _state.auto_engine_pool = _runtime._prepare_auto_engine_pool(_state.config)
        if not _state.auto_engine_pool:
            _state.job["state"] = "failed"
            _runtime._set_job_error(_state.job, "No engine available in automatic mode")
            _runtime._append_event(_state.job, "❌ No engine available in automatic mode")
            _runtime._persist_job(_state.job_id, force=True)
            return _ConversionControl("return", None)
        _state.preferred_auto_engine = _runtime._resolve_auto_preferred_engine(_state.config)
        _state.auto_tuning_summary = _runtime._auto_tune_engine_pool(
            _state.auto_engine_pool,
            hardware_profile=_runtime._hardware_profile,
            network_tier=_state.edge_network_tier,
            total_chars=_state.total_chars,
            force_sequential=_state.force_sequential,
        )
        for _state.pool_config in _state.auto_engine_pool.values():
            _state._apply_engine_overrides(_state.pool_config)
            if _state.force_sequential:
                _state.pool_config.edge_enable_parallel = False
        _state.auto_edge_profile = _state.auto_tuning_summary.get("edge")
        if _state.auto_edge_profile and (
            _state.edge_chunk_override is not None
            or _state.edge_segment_override is not None
            or _state.edge_parallel_override is not None
        ):
            _state.auto_edge_profile = {
                **_state.auto_edge_profile,
                "chunk_chars": _state.edge_chunk_override or _state.auto_edge_profile.get("chunk_chars"),
                "max_segment_seconds": _state.edge_segment_override
                or _state.auto_edge_profile.get("max_segment_seconds"),
                "parallel": bool(_state.edge_parallel_override)
                if _state.edge_parallel_override is not None
                else _state.auto_edge_profile.get("parallel"),
            }
            _state.auto_tuning_summary["edge"] = _state.auto_edge_profile
        if _state.auto_edge_profile:
            _runtime._append_event(
                _state.job,
                "⚡ Auto Edge: "
                f"{_state.auto_edge_profile.get('chunk_chars')} chars, "
                f"{_state.auto_edge_profile.get('max_segment_seconds')}s, "
                f"{_state.auto_edge_profile.get('words_per_minute')} wpm",
            )

    _runtime._append_event(_state.job, "")
    _runtime._append_event(_state.job, f"🎙️ Engine: {_state.active_config.engine}")
    _runtime._append_event(_state.job, f"🗣️ Voice: {_state.active_config.voice or 'default'}")
    _runtime._update_job_activity(_state.job, stage="tts_ready")
    _state.has_edge_engine = (_state.active_config.engine or "").lower() == "edge"
    if not _state.has_edge_engine and _state.auto_engine_pool:
        _state.has_edge_engine = any(
            (pool_config.engine or "").lower() == "edge"
            for pool_config in _state.auto_engine_pool.values()
        )
    _state.edge_auto_tune_flag = (
        _runtime.EDGE_AUTO_TUNE if _state.edge_auto_tune_override is None else bool(_state.edge_auto_tune_override)
    )
    _state.edge_auto_tune = _state.edge_auto_tune_flag and _state.has_edge_engine
    _state.parallel_slots_cap: Optional[int] = 1 if _state.force_sequential else None
    if _state.edge_auto_tune and not _state.force_sequential:
        _state.parallel_slots_cap = _runtime.EDGE_AUTO_PARALLEL_CAPS.get(
            _state.edge_network_tier, _runtime.EDGE_SAFE_CHAPTER_PARALLEL
        )
    _state.requested_slots = (
        1
        if _state.force_sequential
        else max(1, int(_state.job.get("parallelSlots") or _runtime._PARALLEL_SLOTS_DEFAULT))
    )
    _state.parallel_slots = 1 if _state.force_sequential else _runtime._determine_parallel_slots(_state.requested_slots)
    if _state.parallel_slots_cap:
        _state.parallel_slots = min(_state.parallel_slots, _state.parallel_slots_cap)
        _state.requested_slots = min(_state.requested_slots, _state.parallel_slots_cap)
    _state.edge_cap = 0
    if _state.has_edge_engine:
        try:
            _state.edge_cap = int(_runtime.os.getenv("EDGE_MAX_CONCURRENCY", "") or "0")
        except ValueError:
            _state.edge_cap = 0
        if _state.edge_cap > 0:
            _state.parallel_slots = max(1, min(_state.parallel_slots, _state.edge_cap))
    _state.active_jobs = sum(1 for job_data in _runtime.jobs.values() if job_data.get("state") == "running")
    if not _state.force_sequential and _state.active_jobs > 1:
        _state.balanced_slots = max(1, _state.parallel_slots // _state.active_jobs)
        if _state.balanced_slots < _state.parallel_slots:
            _runtime._append_event(
                _state.job,
                f"⚖️ {_state.active_jobs} active conversions → adjusting parallelism {_state.parallel_slots}→{_state.balanced_slots}",
            )
            _state.parallel_slots = _state.balanced_slots
    _state.job["parallelSlots"] = _state.parallel_slots
    if _state.force_sequential:
        _runtime._append_event(_state.job, "🔒 Parallelism disabled (one chapter at a time)")
    elif _state.edge_auto_tune and _state.parallel_slots_cap:
        _runtime._append_event(
            _state.job,
            f"🌐 Edge auto-tune: cap {_state.parallel_slots_cap} chapter(s) in parallel ({_state.edge_network_tier})",
        )
    elif _state.parallel_slots > 1:
        _runtime._append_event(
            _state.job, f"🚀 Automatic parallel: up to {_state.parallel_slots} simultaneous chapters"
        )
    else:
        _runtime._append_event(_state.job, "🔄 Sequential mode: one chapter at a time")

    def _engine_pool_snapshot() -> ResourceSnapshot:
        stats = _runtime.system_monitor.latest() or {}
        cpu_info = stats.get("cpu") or {}
        mem_info = stats.get("memory") or {}
        cpu_percent = float(cpu_info.get("percent") or 0.0)
        cpu_idle = max(0.0, 100.0 - cpu_percent)
        mem_available = float(mem_info.get("available") or 0.0)
        ram_gb = mem_available / (1024**3) if mem_available else 0.0
        active_jobs = sum(1 for job_data in _runtime.jobs.values() if job_data.get("state") == "running")
        return _runtime.ResourceSnapshot(
            cpu_percent=cpu_percent,
            cpu_idle=cpu_idle,
            ram_gb=ram_gb,
            active_jobs=max(1, active_jobs),
        )
    _state._engine_pool_snapshot = _engine_pool_snapshot
