# -*- coding: utf-8 -*-
"""Server engine pool preparation."""

from __future__ import annotations

from pathlib import Path
from typing import Optional

from .config import ConversionConfig
from .conversion_control import ConversionControl as _ConversionControl


async def _server_engine_pool_preparation(_runtime, _state):
    _state.engine_pool = _runtime.JobEnginePool(
        create_engine=_runtime.tts_factory.create_engine,
        parallel_slots=_state.parallel_slots,
        edge_cap=_state.edge_cap,
        hardware_profile=_runtime._hardware_profile,
        stats_provider=_state._engine_pool_snapshot,
    )
    _state.registered_engines: set[str] = set()
    if _state.auto_mode:
        for _state.name, _state.pool_config in _state.auto_engine_pool.items():
            _state.engine_pool.register_engine(_state.name, _state.pool_config, _state.engine_seeds.get(_state.name))
            _state.registered_engines.add(_state.name)
    else:
        for _state.candidate in _state.engine_chain:
            _state.name = (_state.candidate.engine or "").lower()
            if not _state.name or _state.name in _state.registered_engines:
                continue
            _state.engine_pool.register_engine(_state.name, _state.candidate, _state.engine_seeds.get(_state.name))
            _state.registered_engines.add(_state.name)

    _state.job_output_dir = _runtime._job_output_dir(_state.job_id, _state.job, ensure=True)
    _state.resume_mode = (
        bool(_state.job.get("resumeRequested"))
        and _state.job_output_dir.exists()
        and not _state.force_reprocess_flag
    )

    # Preserve uploaded source file before cleaning the output directory.
    _state.source_path_str = _state.job.get("file_path")
    if _state.source_path_str:
        _state.source_path = _runtime.Path(_state.source_path_str)
        try:
            if _state.source_path.exists() and _state.source_path.is_relative_to(_state.job_output_dir):
                _state.safe_source = _state.job_output_dir / f"{_state.job_id}_{_state.source_path.name}"
                _state.safe_source.parent.mkdir(parents=True, exist_ok=True)
                _runtime.shutil.move(str(_state.source_path), str(_state.safe_source))
                _state.job["file_path"] = str(_state.safe_source)
                _state.source_path = _state.safe_source
        except ValueError:
            # Path.is_relative_to not supported for unrelated paths prior to 3.9
            pass

    # Preserve cover file (used for the preview) while resetting the directory.
    _state.cover_restore: Optional[tuple[_runtime.Path, _runtime.Path]] = None
    if not _state.resume_mode:
        _state.cover_entry = _state.job.get("cover") or {}
        _state.cover_name = _state.cover_entry.get("name")
        if _state.cover_name:
            _state.cover_path = _state.job_output_dir / _state.cover_name
            if _state.cover_path.exists():
                _state.temp_cover = _state.job_output_dir.parent / f"{_state.job_id}_{_state.cover_name}.tmp"
                try:
                    _runtime.shutil.move(str(_state.cover_path), str(_state.temp_cover))
                    _state.cover_restore = (_state.temp_cover, _state.cover_path)
                except Exception:
                    _state.cover_restore = None

        if _state.job_output_dir.exists():
            _runtime.shutil.rmtree(_state.job_output_dir, ignore_errors=True)
        _state.job_output_dir.mkdir(parents=True, exist_ok=True)

        if _state.cover_restore:
            _state.temp_cover, _state.target_cover = _state.cover_restore
            try:
                _runtime.shutil.move(str(_state.temp_cover), str(_state.target_cover))
            except Exception:
                with _runtime.contextlib.suppress(FileNotFoundError):
                    _state.temp_cover.unlink(missing_ok=True)
    else:
        _state.job_output_dir.mkdir(parents=True, exist_ok=True)
    if _state.resume_mode:
        _runtime._append_event(
            _state.job, "♻️ Resuming previous conversion - keeping already generated chapters"
        )

    _state.book_safe_name = _runtime.FileManager.sanitize_filename(_state.title)
    _state.zip_file = _state.job_output_dir / f"{_state.book_safe_name}.zip"
    _state.zip_archive = _runtime.zipfile.ZipFile(_state.zip_file, "w", _runtime.zipfile.ZIP_STORED)
    _state.zip_open = True
    _state.outputs: list[dict] = []
    _state.completed_indices: set[int] = set()
    if _state.resume_mode:
        _state.existing_outputs, _state.completed_indices = await _runtime._preload_existing_outputs(
            _state.job, _state.chapters, _state.job_output_dir
        )
        if _state.existing_outputs:
            _state.outputs.extend(_state.existing_outputs)
            _runtime._append_event(_state.job, f"⏩ {len(_state.existing_outputs)} chapter(s) were already converted")
            _state.job["chaptersCompleted"] = len(_state.completed_indices)
            for _state.completed_idx in _state.completed_indices:
                _state._complete_chapter_progress(_state.completed_idx, broadcast=False)
            _state._update_job_progress(force_broadcast=True)

    if _state._should_abort_current_run("🛑 Conversion cancelled after processing chapters"):
        return _ConversionControl("return", None)
    _runtime._update_job_activity(_state.job, stage="output_ready")

    if _state.cached_cover_path:
        _state.filename = _state.cached_cover_path.name
        _state.target_cover = _state.job_output_dir / _state.filename
        try:
            _runtime.shutil.copy2(_state.cached_cover_path, _state.target_cover)
            _state.cover_url = f"/api/outputs/{_state.job_id}/{_state.filename}"
            _state.job["cover"] = {
                "name": _state.filename,
                "url": _state.cover_url,
                "mimeType": _state.cached_cover_entry.get("mime"),
            }
            _state.job["coverUrl"] = _state.cover_url
            _state.job["coverMimeType"] = _state.cached_cover_entry.get("mime")
            _runtime._append_event(_state.job, "🖼️ Cover reused from cache")
            _runtime._persist_job(_state.job_id, force=True)
        except Exception as cover_exc:
            _state.cover_exc = cover_exc
            _runtime._append_event(_state.job, f"⚠️ Failed to reuse cover: {_state.cover_exc}")
    elif _state.cover_blob:
        _state.original_name = _runtime.Path(_state.job.get("file_path", "")).name
        _state.cover_slug = (
            _runtime.FileManager.sanitize_filename(_state.title)
            or _runtime.FileManager.sanitize_filename(_state.original_name)
            or "capa"
        )
        _state.filename = f"{_state.cover_slug}_cover{_state.cover_blob.extension}"
        _state.cover_path = _state.job_output_dir / _state.filename
        try:
            _state.cover_path.write_bytes(_state.cover_blob.data)
            _runtime._store_cover_in_cache(_state.file_hash, _state.cover_blob)
            _state.cover_url = f"/api/outputs/{_state.job_id}/{_state.filename}"
            _state.job["cover"] = {
                "name": _state.filename,
                "url": _state.cover_url,
                "mimeType": _state.cover_blob.media_type,
            }
            _state.job["coverUrl"] = _state.cover_url
            _state.job["coverMimeType"] = _state.cover_blob.media_type
            _runtime._append_event(_state.job, "🖼️ Book cover detected")
            _runtime._persist_job(_state.job_id, force=True)
        except Exception as cover_exc:
            _state.cover_exc = cover_exc
            _runtime._append_event(_state.job, f"⚠️ Failed to save cover: {_state.cover_exc}")
            _state.job["cover"] = None
            _state.job["coverUrl"] = None
            _state.job["coverMimeType"] = None

    def _resolve_tts_output(target_mp3: Path, engine_name: str) -> tuple[Path, bool]:
        return _runtime.resolve_tts_output(target_mp3, engine_name)
    _state._resolve_tts_output = _resolve_tts_output

    def _switch_to_next_engine(reason: str) -> bool:
        if _state.engine_index + 1 >= len(_state.engine_chain):
            return False
        _runtime._append_event(_state.job, f"🔁 {reason} → trying fallback")

        while _state.engine_index + 1 < len(_state.engine_chain):
            _state.engine_index += 1
            candidate = _state.engine_chain[_state.engine_index]
            engine_name = (candidate.engine or "").lower()
            if not engine_name or engine_name in _state.unavailable_engines:
                _runtime._append_event(_state.job, "   ↳ Engine unavailable, skipping")
                continue
            # Distinguish Edge monolingual fallback from a full engine switch
            prev_config = _state.engine_chain[_state.engine_index - 1] if _state.engine_index > 0 else None
            if (
                engine_name == "edge"
                and prev_config is not None
                and (prev_config.engine or "").lower() == "edge"
                and candidate.voice != prev_config.voice
            ):
                _runtime._append_event(
                    _state.job,
                    f"   ↳ Switching to Edge monolingual voice ({candidate.voice})...",
                )
            else:
                _runtime._append_event(_state.job, f"   ↳ Activating engine '{candidate.engine}'...")
            _state.active_config = candidate
            if engine_name == "piper":
                chars = len(getattr(_state.chapter, "text", "") or "")
                edge_secs = max(1, chars // 800)
                piper_secs = max(1, chars // 100)
                time_note = (
                    f"~{piper_secs}s vs {edge_secs}s on Edge"
                    if piper_secs < 120
                    else f"~{piper_secs // 60}min vs {edge_secs}s on Edge"
                )
                _runtime._append_event(
                    _state.job,
                    f"   ⚠️ PIPER FALLBACK ({time_note}) — "
                    "set DISABLE_PIPER_FALLBACK=1 to retry Edge instead",
                )
            _runtime._append_event(
                _state.job,
                f"   ✅ Now using {candidate.engine.upper()} ({candidate.voice or 'default'})",
            )
            return True
        return False
    _state._switch_to_next_engine = _switch_to_next_engine

    _state.zip_lock = _runtime.asyncio.Lock()
    _state.job_failed = {"value": False}
    _state.edge_slow_mode = False
    # Count consecutive Edge chapter timeouts across all chapters.
    # After _EDGE_TIMEOUT_DISABLE_THRESHOLD failures, Edge is disabled for the whole job
    # so subsequent chapters skip the 60s wait and go straight to the next engine.
    _state._EDGE_TIMEOUT_DISABLE_THRESHOLD = 2
    _state.edge_chapter_timeouts = [0]  # mutable container for nonlocal mutation in nested fns
    _state.edge_safe_profile = {
        "chunk_chars": _runtime.EDGE_SAFE_CHUNK_CHARS,
        "max_segment_seconds": _runtime.EDGE_SAFE_MAX_SEGMENT_SECONDS,
        "parallel_cap": _runtime.EDGE_SAFE_CHAPTER_PARALLEL,
        "timeout_max": _runtime.EDGE_SAFE_TIMEOUT_MAX,
    }
    _state.edge_configs: list[_runtime.ConversionConfig] = []
    _state._edge_cfg_seen: set[int] = set()
    for _state.cfg in (
        _state.config,
        _state.active_config,
        _state.auto_engine_pool.get("edge") if _state.auto_engine_pool else None,
    ):
        if _state.cfg and (_state.cfg.engine or "").lower() == "edge":
            if id(_state.cfg) not in _state._edge_cfg_seen:
                _state.edge_configs.append(_state.cfg)
                _state._edge_cfg_seen.add(id(_state.cfg))

    _state.audio_duplicate_tracker = _runtime.AudioDuplicateTracker()

    def _apply_edge_slow_mode(reason: str) -> None:
        if not _state.edge_auto_tune or _state.edge_slow_mode:
            return
        _state.edge_slow_mode = True
        _state.job["_edgeSlowMode"] = True
        cap = max(1, int(_state.edge_safe_profile["parallel_cap"] or 1))
        if _state.parallel_slots_cap:
            cap = min(cap, _state.parallel_slots_cap)
        _state.parallel_slots_cap = cap
        _state.requested_slots = min(_state.requested_slots, cap)
        _state.parallel_slots = min(_state.parallel_slots, cap)
        _state.job["parallelSlots"] = _state.parallel_slots
        safe_cap = int(_state.edge_safe_profile["chunk_chars"])
        for cfg in _state.edge_configs:
            cfg.edge_chunk_chars = _runtime.degrade_edge_chunk_chars(
                cfg.edge_chunk_chars, floor=4000, cap=safe_cap
            )
            cfg.edge_max_segment_seconds = min(
                cfg.edge_max_segment_seconds or _state.edge_safe_profile["max_segment_seconds"],
                _state.edge_safe_profile["max_segment_seconds"],
            )
            cfg.edge_enable_parallel = False
        _state.engine_pool.update_parallel_slots(_state.parallel_slots)
        _state.slot_affinity = []  # disable multi-engine affinity in slow mode
        _runtime._append_event(
            _state.job,
            f"🧯 Edge safe mode: {reason} → chunk={_state.edge_safe_profile['chunk_chars']} seg={_state.edge_safe_profile['max_segment_seconds']}s parallel={_state.parallel_slots}",
        )
    _state._apply_edge_slow_mode = _apply_edge_slow_mode

    def _available_auto_pool() -> dict[str, ConversionConfig]:
        if not _state.auto_engine_pool:
            return {}
        return {
            name: cfg
            for name, cfg in _state.auto_engine_pool.items()
            if name not in _state.unavailable_engines
        }
    _state._available_auto_pool = _available_auto_pool

    def _apply_auto_edge_profile(engine_obj: object) -> None:
        if not _state.auto_edge_profile or not hasattr(engine_obj, "apply_speed_profile"):
            return
        if getattr(engine_obj, "_auto_profile_applied", False):
            return
        try:
            engine_obj.apply_speed_profile(
                chunk_char_limit=_state.auto_edge_profile.get("chunk_chars"),
                max_segment_seconds=_state.auto_edge_profile.get("max_segment_seconds"),
                words_per_minute=_state.auto_edge_profile.get("words_per_minute"),
            )
            setattr(engine_obj, "_auto_profile_applied", True)
        except Exception:
            pass
    _state._apply_auto_edge_profile = _apply_auto_edge_profile
