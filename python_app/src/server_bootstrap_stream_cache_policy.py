# -*- coding: utf-8 -*-
"""Ordered legacy server initialization at the facade seam."""

from __future__ import annotations


def _initialize_server_stream_cache_policy(_runtime):
    _runtime._stream_index_path = _runtime._bind_server_function(_runtime._server_server_stream_index._stream_index_path, _runtime.sys.modules[_runtime.__name__])


    _runtime._load_stream_index = _runtime._bind_server_function(_runtime._server_server_stream_index._load_stream_index, _runtime.sys.modules[_runtime.__name__])


    _runtime._atomic_write_text = _runtime._bind_server_function(_runtime._server_server_stream_index._atomic_write_text, _runtime.sys.modules[_runtime.__name__])


    _runtime._retired_stream_chunks = _runtime._bind_server_function(_runtime._server_server_stream_index._retired_stream_chunks, _runtime.sys.modules[_runtime.__name__])


    _runtime._save_stream_index = _runtime._bind_server_function(_runtime._server_server_stream_index._save_stream_index, _runtime.sys.modules[_runtime.__name__])


    # Parallel chapter conversion performs read-modify-write updates to one
    # per-job manifest. Serialize those updates so chapters cannot erase each
    # other's published chunks.
    _runtime._stream_manifest_lock = _runtime.threading.Lock()


    _runtime._load_cover_cache = _runtime._bind_server_function(_runtime._server_server_cache_markers._load_cover_cache, _runtime.sys.modules[_runtime.__name__])


    _runtime._save_cover_cache = _runtime._bind_server_function(_runtime._server_server_cache_markers._save_cover_cache, _runtime.sys.modules[_runtime.__name__])


    _runtime.cover_cache_index = _runtime._load_cover_cache()

    # Initialize job manager with persistence
    _runtime.jobs_state_dir = _runtime.JOBS_DIR
    _runtime.job_manager = _runtime.JobManager(_runtime.jobs_state_dir)
    _runtime._restart_marker_path = _runtime.persistent_root / ".restart_marker.json"
    _runtime._skip_resume_on_startup = False


    _runtime._load_restart_marker = _runtime._bind_server_function(_runtime._server_server_cache_markers._load_restart_marker, _runtime.sys.modules[_runtime.__name__])


    _runtime._write_restart_marker = _runtime._bind_server_function(_runtime._server_server_cache_markers._write_restart_marker, _runtime.sys.modules[_runtime.__name__])


    _runtime._clear_restart_marker = _runtime._bind_server_function(_runtime._server_server_cache_markers._clear_restart_marker, _runtime.sys.modules[_runtime.__name__])


    _runtime._skip_resume_on_startup = bool(_runtime._load_restart_marker())
    _runtime._PIPER_SUPPORTED = _runtime._IS_TEST_ENV or _runtime.is_piper_supported_environment()


    _runtime._has_kokoro_support = _runtime._bind_server_function(_runtime._server_server_output_policy._has_kokoro_support, _runtime.sys.modules[_runtime.__name__])


    _runtime._has_piper_support = _runtime._bind_server_function(_runtime._server_server_output_policy._has_piper_support, _runtime.sys.modules[_runtime.__name__])


    _runtime._has_spark_support = _runtime._bind_server_function(_runtime._server_server_output_policy._has_spark_support, _runtime.sys.modules[_runtime.__name__])


    _runtime._has_coqui_support = _runtime._bind_server_function(_runtime._server_server_output_policy._has_coqui_support, _runtime.sys.modules[_runtime.__name__])


    _runtime._JOB_WORKERS = max(1, int(_runtime.os.getenv("JOB_WORKERS", "1") or "1"))  # Processar 1 livro por vez
    _runtime._job_queue: _runtime.Optional[_runtime.asyncio.Queue[str]] = None
    _runtime.__dict__.setdefault("__annotations__", {})['_job_queue'] = 'Optional[asyncio.Queue[str]]'
    _runtime._job_workers: list[_runtime.asyncio.Task] = []
    _runtime.__dict__.setdefault("__annotations__", {})['_job_workers'] = 'list[asyncio.Task]'
    _runtime._jobs_in_queue: set[str] = set()
    _runtime.__dict__.setdefault("__annotations__", {})['_jobs_in_queue'] = 'set[str]'
    _runtime._job_tasks: dict[str, _runtime.asyncio.Task] = {}
    _runtime.__dict__.setdefault("__annotations__", {})['_job_tasks'] = 'dict[str, asyncio.Task]'
    _runtime._worker_scale_lock = _runtime.asyncio.Lock()

    _runtime._pending_uploads: _runtime.Dict[str, dict] = {}
    _runtime.__dict__.setdefault("__annotations__", {})['_pending_uploads'] = 'Dict[str, dict]'
    _runtime._pending_lock = _runtime.threading.Lock()
    # Local desktop keeps uploads for 30 days (file lives on disk, rarely needs cleanup).
    # HF Spaces keeps them for 1 hour to avoid filling the /data volume.
    _runtime._PENDING_TTL_SECONDS = int(
        _runtime.os.getenv(
            "UPLOAD_TTL_SECONDS",
            str(30 * 24 * 3600 if not _runtime.os.getenv("SPACE_ID") else 3600),
        )
    )
    _runtime._PENDING_META_FILENAME = "upload.json"
    _runtime._CHAPTER_HEARTBEAT_SECONDS = 20.0  # was 45s — more frequent activity pings
    _runtime._CHAPTER_TIMEOUT_FACTOR = 2.0  # was 2.5 — less overshoot on estimated duration
    _runtime._CHAPTER_TIMEOUT_MIN = 60.0  # was 120s — detect stuck chapters faster
    # Locally, allow up to 1800s (30 min) for unusually large chapters that the
    # auto-split may have missed (e.g. cached parses from before the split was
    # applied).  On HF we use the same cap because Edge is often the only working
    # engine and chapters can be 50–70 K chars (needing 1000+ s at 60 chars/s).
    # _resolve_chapter_timeout scales the effective cap with chapter size.
    _runtime._CHAPTER_TIMEOUT_MAX = 1800.0
    try:
        _runtime._CHAPTER_RETRY_MAX = max(0, int(_runtime.os.getenv("CHAPTER_RETRY_MAX", "6") or "6"))
    except (TypeError, ValueError):
        _runtime._CHAPTER_RETRY_MAX = 3
    # Retry forever was causing infinite loops when ALL engines fail (e.g. on HF
    # where fallback engines aren't available). Use a finite retry count instead.
    _runtime._CHAPTER_RETRY_FOREVER = False
    _runtime._CHAPTER_RETRY_FOREVER_MAX = max(
        1, int(_runtime.os.getenv("CHAPTER_RETRY_FOREVER_MAX", "5") or "5")
    )  # hard cap even if retry_forever were re-enabled
    try:
        _runtime._CHAPTER_RETRY_ROUNDS = max(0, int(_runtime.os.getenv("CHAPTER_RETRY_ROUNDS", "3") or "3"))
    except (TypeError, ValueError):
        _runtime._CHAPTER_RETRY_ROUNDS = 3  # was 1 — give more rounds before giving up
    try:
        _runtime._CHAPTER_RETRY_BACKOFF_SECONDS = float(
            _runtime.os.getenv("CHAPTER_RETRY_BACKOFF_SECONDS", "2.0") or "2.0"
        )
    except (TypeError, ValueError):
        _runtime._CHAPTER_RETRY_BACKOFF_SECONDS = 2.0
    _runtime._STALL_THRESHOLD_SECONDS = float(_runtime.os.getenv("JOB_STALL_THRESHOLD_SECONDS", "300") or "300")
    _runtime._STALL_RECHECK_SECONDS = float(_runtime.os.getenv("JOB_STALL_RECHECK_SECONDS", "90") or "90")
    _runtime._STALL_MAX_AUTO_RETRIES = max(0, int(_runtime.os.getenv("JOB_STALL_MAX_AUTO_RETRIES", "1") or "1"))
