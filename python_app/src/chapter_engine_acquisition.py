# -*- coding: utf-8 -*-
"""Chapter engine acquisition."""

from __future__ import annotations

from pathlib import Path
from typing import Optional


async def _chapter_engine_acquisition(self, _state):
    from . import converter as _runtime
    _state.current_engine_label = (
        _state.engine_tracker.get("label") or (_state.config.engine or "").lower()
    )
    _state.tts_output_path, _state.needs_mp3_transcode = _state._resolve_tts_output_path(
        _state.output_path, _state.current_engine_label
    )
    _state.last_tts_output_path = _state.tts_output_path
    _state.last_needs_transcode = _state.needs_mp3_transcode

    # Create progress callback for granular updates
    def on_segment_complete(text: str, total_chars: int):
        self.progress.update_chars_progress(text, total_chars)
        self._mark_health_activity(_state.chapter_num, "segment")
        _state.segment_progress_state["hits"] += 1
        self._record_segment_success(
            engine_label=_state.engine_tracker.get("label")
            or (_state.config.engine or "").lower(),
            chapter_index=_state.chapter_num,
            segment_chars=len(text or ""),
            engine_pool=_state.engine_pool,
            config=_state.engine_config,
        )
    _state.on_segment_complete = on_segment_complete

    def on_pre_segment(text: str, total_chars: int):
        segment_chars = len(text or "")
        self._mark_health_activity(_state.chapter_num, "pre-segment")
        self._pre_segment_health_check(
            engine_label=_state.engine_tracker.get("label")
            or (_state.config.engine or "").lower(),
            segment_chars=segment_chars,
            engine_pool=_state.engine_pool,
            config=_state.engine_config,
            engine_obj=_state.engine_instance.get("object"),
        )
    _state.on_pre_segment = on_pre_segment

    _state.chunk_callback = None
    _state.chunk_root: Optional[_runtime.Path] = None
    _state.chunk_base: Optional[_runtime.Path] = None
    _state.job_id = getattr(_state.config, "job_id", None)
    if _state.job_id:
        _state.chunk_base = _runtime.Path(_state.config.output_dir) / "streams" / str(_state.job_id)
    else:
        _state.cache_root = getattr(_state.config, "cache_dir", None)
        if _state.cache_root:
            _state.chunk_base = _runtime.Path(_state.cache_root) / "streams" / "cli"
    if _state.chunk_base:
        # Use chapter's unique index label (e.g. "1.0", "1.1") for dir name
        # to avoid collisions between sub-chapters in parallel mode
        _state._ch_label = self._chapter_index_label(_state.chapter, _state.idx + 1)
        _state._ch_label_safe = _state._ch_label.replace(".", "_")
        _state.chunk_root = _state.chunk_base / f"chapter_{_state._ch_label_safe}"
        try:
            # **RESUME**: Don't delete existing chunks - Edge engine will resume
            _state.chunk_root.mkdir(parents=True, exist_ok=True)
        except Exception:
            _state.chunk_root = None
    if _state.chunk_root and _state.chunk_root.exists():
        _state.disable_resume = str(
            (getattr(_state.config, "extra", {}) or {}).get(
                "disable_chunk_resume", "0"
            )
        ).strip().lower() in {"1", "true", "yes", "on"}
        # Avoid retry loops: after first chapter attempt, discard stale chunks
        # so we don't keep replaying the same failing segment payload.
        # Also discard when force_reprocess/clear_cache is set — stale chunks
        # must not be resumed when the user explicitly requests a fresh run.
        _state.resume_allowed = (
            (not _state.disable_resume)
            and _state.chapter_attempt == 1
            and _state.attempt == 0
            and not getattr(_state.config, "force_reprocess", False)
            and not getattr(_state.config, "clear_cache", False)
        )
        if not _state.resume_allowed:
            try:
                for _state.stale in _state.chunk_root.glob("chunk_*.*"):
                    _state.stale.unlink(missing_ok=True)
                (_state.chunk_root / "manifest.json").unlink(missing_ok=True)
                if self.verbose:
                    self.progress.tick(
                        "🧹 Clearing stale chunks before retry (anti-loop)"
                    )
            except Exception:
                pass
        try:
            _state.existing_chunks = [
                path for path in _state.chunk_root.glob("chunk_*.mp3")
                if _runtime.re.fullmatch(r"chunk_\d+\.mp3", path.name)
            ]
        except Exception:
            _state.existing_chunks = []
        if _state.existing_chunks:
            self.progress.tick(
                f"♻️ Resuming {len(_state.existing_chunks)} chunk(s) already ready"
            )

    def on_chunk_ready(
        segment_index: int,
        temp_path: Path,
        segment_text: Optional[str] = None,
        *,
        observation=None,
    ) -> None:
        _state.segment_progress_state["hits"] += 1
        # Update bar with completed chunks
        if hasattr(self, "progress"):
            try:
                self.progress.update_chunk_progress(segment_index)
            except Exception:
                pass

        if _state.chunk_root is None:
            return
        published_target = None
        try:
            canonical = (
                _state.chunk_root / f"chunk_{segment_index:04d}{temp_path.suffix}"
            )
            if observation is None:
                raise RuntimeError("Missing segment publication context")
            if temp_path.resolve() != canonical.resolve():
                _runtime.atomic_copy_audio(temp_path, canonical)
            # Keep resume-cache naming unchanged while every
            # manifest points to immutable published bytes.
            publication_id = _runtime.uuid.uuid4().hex
            target = _state.chunk_root / f"chunk_stream_{publication_id}{temp_path.suffix}"
            observation_payload = observation.publish_audio(temp_path, target)
            published_target = target
            manifest_path = _state.chunk_root / "manifest.json"
            manifest = {
                "jobId": _state.job_id or "cli",
                "chapterIndex": _state.chapter_num,
                "chunks": [],
            }
            if manifest_path.exists():
                try:
                    manifest = _runtime.json.loads(
                        manifest_path.read_text(encoding="utf-8")
                    )
                except Exception:
                    manifest = {
                        "jobId": _state.job_id or "cli",
                        "chapterIndex": _state.chapter_num,
                        "chunks": [],
                    }
            existing = manifest.get("chunks") or []
            existing = [
                entry for entry in existing if isinstance(entry, dict)
            ]
            existing_by_index = {
                entry.get("index"): entry for entry in existing
            }
            previous = existing_by_index.get(segment_index) or {}
            entry = {
                "id": publication_id,
                "index": segment_index,
                "file": target.name,
                "observation": observation_payload,
            }
            if _state.job_id:
                entry["url"] = (
                    f"/api/streams/{_state.job_id}/chapters/"
                    f"{_state.chapter_num}/chunks/{publication_id}"
                )
            if segment_text:
                entry["text"] = segment_text
            elif previous.get("text"):
                entry["text"] = previous["text"]
            existing_by_index[segment_index] = entry
            manifest["chunks"] = sorted(
                existing_by_index.values(),
                key=lambda item: item.get("index", 0),
            )
            manifest["updatedAt"] = _runtime.time.time()
            manifest["baseUrl"] = (
                f"/api/streams/{_state.job_id}/chapters/{_state.chapter_num}"
                if _state.job_id
                else ""
            )
            _runtime.atomic_write_manifest(manifest_path, manifest)
            published_target = None
        except Exception as exc:
            if published_target is not None:
                with _runtime.contextlib.suppress(OSError):
                    published_target.unlink(missing_ok=True)
            if self.verbose:
                print(f"   ⚠️ Failure saving chunk {segment_index}: {exc}")
    _state.on_chunk_ready = on_chunk_ready

    # Only use callback/chunking when a resume directory is available
    _state.chunk_callback = _state.on_chunk_ready if _state.chunk_root else None
    _state.primary_chunk_callback = _state.chunk_callback
    _state.primary_chunk_root = _state.chunk_root if _state.chunk_root else None

    _state.stall_event = _runtime.asyncio.Event()
    _state.slow_switch_event = _runtime.asyncio.Event()
    _state.segment_progress_state = {"hits": 0}
    # Reset stall reference when a new synthesis attempt starts
    # (including engine switches within the same chapter).
    with _runtime.contextlib.suppress(Exception):
        self.progress.mark_activity()
    _state.synthesis_task = _runtime.asyncio.create_task(
        _state._synthesize_safe(
            _state.tts_engine,
            _state.speech_text,
            _state.tts_output_path,
            formatting_segments=(
                None
                if _state.payload_locked
                else getattr(_state.chapter, "formatting_segments", None)
            ),
            progress_callback=_state.on_segment_complete,
            pre_segment_callback=_state.on_pre_segment,
            chunk_callback=_state.primary_chunk_callback,
            resume_chunks_dir=_state.primary_chunk_root,
        )
    )
    _state.stall_task = _runtime.asyncio.create_task(
        self._watch_chapter_stall(
            _state.chapter_num,
            _state.synthesis_task,
            _state.stall_seconds,
            _state.stall_event,
            probe_dir=_runtime.Path(getattr(_state.config, "cache_dir", "") or ""),
        )
    )
    # Per-chapter idle watchdog: immune to shared
    # progress timer (which is reset by sibling
    # chapters running in parallel).  Always on.
    try:
        _state._seg_idle_seconds = float(
            _runtime.os.getenv("CHAPTER_SEGMENT_IDLE_SECONDS", "180") or "180"
        )
    except ValueError:
        _state._seg_idle_seconds = 180.0
    _state.segment_idle_task = _runtime.asyncio.create_task(
        self._watch_segment_idle(
            _state.chapter_num,
            _state.synthesis_task,
            _state.segment_progress_state,
            _state._seg_idle_seconds,
            stall_event=_state.stall_event,
            label="segment",
        )
    )
    _state.slow_task: Optional[_runtime.asyncio.Task] = None
