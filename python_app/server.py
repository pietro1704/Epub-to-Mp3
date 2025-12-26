#!/usr/bin/env python3
"""FastAPI server for converting EPUBs into spoken MP3 chapters."""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import json
import logging
import os
import shutil
import uuid
import zipfile
from pathlib import Path
import re
from typing import Dict, Optional, List
from dataclasses import replace
import time
import threading
from datetime import datetime

logger = logging.getLogger(__name__)

from fastapi import BackgroundTasks, FastAPI, File, Form, HTTPException, UploadFile, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel

from src.config import ConversionConfig
from src.ebook_reader import EbookReader
from src.tts.factory import TTSFactory
from src.storage_manager import get_storage_manager
from src.utils import FileManager, AudioProcessor, TextValidator
from src.cache_manager import CacheManager
from src.paths import OUTPUT_DIR
from src.job_manager import JobManager
from src.text_formatting import TextFormattingProcessor
from src.telemetry import TelemetryRecorder
from main import ConverterApplication
from src.chapter_utils import deduplicate_chapters_by_content

app = FastAPI(title="EPUB to MP3 Converter API")

ROOT_DIR = Path(__file__).resolve().parents[1]
WEB_DIR = ROOT_DIR / "web"
SAMPLE_BOOK_CANDIDATES = [
    WEB_DIR / "dist" / "sample.epub",
    WEB_DIR / "public" / "sample.epub",
]

# Job cleanup configuration
COMPLETED_JOB_TTL_HOURS = 1  # Keep completed jobs for 1 hour
CLEANUP_INTERVAL_SECONDS = 300  # Run cleanup every 5 minutes

# Initialize storage manager (R2)
storage = get_storage_manager()

# CORS configuration - supports both local dev and Cloudflare deployment
allowed_origins = [
    "http://localhost:5173",
    "http://localhost:3000",
    "http://localhost:8000",
]

# Add Cloudflare Pages domain from environment (for production)
cloudflare_domain = os.getenv("CLOUDFLARE_PAGES_URL")
if cloudflare_domain:
    allowed_origins.append(cloudflare_domain)
    allowed_origins.append(cloudflare_domain.replace("http://", "https://"))

# Add custom frontend URL if provided
frontend_url = os.getenv("FRONTEND_URL")
if frontend_url:
    allowed_origins.append(frontend_url)

app.add_middleware(
    CORSMiddleware,
    allow_origins=allowed_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def _parse_form_bool(value: Optional[str], default: bool = True) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    normalized = str(value).strip().lower()
    if not normalized:
        return default
    return normalized in {"1", "true", "yes", "on", "enabled"}


def _normalize_locale(value: Optional[str], default: str = "pt") -> str:
    locale_value = (value or default or "pt").split("-", 1)[0].lower()
    if locale_value not in {"pt", "en"}:
        locale_value = "en"
    return locale_value

# Para deployments em cloud (HF Spaces, etc.), use /tmp; caso contrário, usa OUTPUT_DIR da raiz do projeto
# Se OUTPUT_DIR env var estiver definida, usa ela; senão usa OUTPUT_DIR do paths.py
if os.getenv("OUTPUT_DIR"):
    output_dir = Path(os.getenv("OUTPUT_DIR"))
elif os.getenv("SPACE_ID"):  # HuggingFace Spaces
    output_dir = Path("/tmp/output")
else:
    output_dir = OUTPUT_DIR

output_dir.mkdir(exist_ok=True, parents=True)

# Dados persistentes (jobs/inputs) precisam sobreviver a reinícios em HF Spaces
if os.getenv("SPACE_ID"):
    persistent_root = Path(os.getenv("PERSISTENT_ROOT", "/data/epub-to-mp3"))
else:
    persistent_root = Path(os.getenv("PERSISTENT_ROOT", str(output_dir)))
persistent_root.mkdir(exist_ok=True, parents=True)

uploads_dir = persistent_root / ".uploads"
uploads_dir.mkdir(exist_ok=True, parents=True)
job_inputs_dir = persistent_root / ".job_inputs"
job_inputs_dir.mkdir(exist_ok=True, parents=True)
cover_cache_dir = output_dir / ".cover_cache"
cover_cache_dir.mkdir(exist_ok=True, parents=True)
cover_index_path = cover_cache_dir / "index.json"


def _load_cover_cache() -> Dict[str, dict]:
    try:
        return json.loads(cover_index_path.read_text())
    except Exception:
        return {}


def _save_cover_cache(index: Dict[str, dict]) -> None:
    try:
        cover_index_path.write_text(json.dumps(index))
    except Exception:
        pass


cover_cache_index = _load_cover_cache()

# Initialize job manager with persistence
jobs_state_dir = persistent_root / ".jobs"
job_manager = JobManager(jobs_state_dir)

_JOB_WORKERS = max(1, int(os.getenv("JOB_WORKERS", "2") or "2"))
_job_queue: Optional[asyncio.Queue[str]] = None
_job_workers: list[asyncio.Task] = []
_jobs_in_queue: set[str] = set()

_pending_uploads: Dict[str, dict] = {}
_pending_lock = threading.Lock()
_PENDING_TTL_SECONDS = 3600  # 1 hour
_CHAPTER_HEARTBEAT_SECONDS = 45.0
_CHAPTER_TIMEOUT_FACTOR = 2.5
_CHAPTER_TIMEOUT_MIN = 120.0
_CHAPTER_TIMEOUT_MAX = 900.0

def _resolve_max_chapter_limit() -> int:
    """Return the max number of chapters allowed per job (0 = sem limite)."""
    env_limit = os.getenv("MAX_CHAPTERS_PER_JOB")
    if env_limit:
        try:
            return max(0, int(env_limit))
        except (TypeError, ValueError):
            logger.warning("Invalid MAX_CHAPTERS_PER_JOB value: %s", env_limit)
    return 0


MAX_CHAPTERS_PER_JOB = _resolve_max_chapter_limit()


def _cleanup_pending_uploads() -> None:
    cutoff = time.time() - _PENDING_TTL_SECONDS
    expired: List[str] = []
    with _pending_lock:
        for upload_id, entry in list(_pending_uploads.items()):
            if entry.get("created_at", 0) < cutoff:
                expired.append(upload_id)
                _pending_uploads.pop(upload_id, None)
    for upload_id in expired:
        upload_dir = uploads_dir / upload_id
        if upload_dir.exists():
            shutil.rmtree(upload_dir, ignore_errors=True)


def _enforce_chapter_limit(chapter_count: int) -> None:
    if MAX_CHAPTERS_PER_JOB and chapter_count > MAX_CHAPTERS_PER_JOB:
        logger.warning(
            "Job rejected: %s chapters exceeds limit of %s",
            chapter_count,
            MAX_CHAPTERS_PER_JOB,
        )
        raise HTTPException(
            status_code=413,
            detail=(
                f"Este livro possui {chapter_count} capítulos, mas o limite atual é "
                f"de {MAX_CHAPTERS_PER_JOB}. Envie trechos menores ou selecione menos capítulos."
            ),
        )


def _summarize_resume_job(job_id: str, job_data: dict, saved_at: Optional[str] = None) -> dict:
    return {
        "jobId": job_id,
        "state": job_data.get("state", "queued"),
        "bookTitle": job_data.get("bookTitle", "Livro Desconhecido"),
        "fileName": Path(job_data.get("file_path", "")).name if job_data.get("file_path") else "unknown",
        "savedAt": saved_at or job_data.get("_saved_at") or datetime.utcnow().isoformat(),
        "chaptersCompleted": job_data.get("chaptersCompleted", 0),
        "chaptersTotal": job_data.get("chaptersTotal"),
        "engine": job_data.get("engine"),
        "voice": job_data.get("voice"),
        "language": job_data.get("detectedLanguage") or job_data.get("language"),
        "formattingCues": job_data.get("formattingCues"),
        "uiLanguage": job_data.get("uiLanguage"),
    }


def _resolve_chapter_timeout(estimated_seconds: float) -> float:
    """Return an upper bound for synthesis before forcing fallback."""
    estimate = max(float(estimated_seconds or 0.0), _CHAPTER_TIMEOUT_MIN)
    timeout = max(_CHAPTER_TIMEOUT_MIN, estimate * _CHAPTER_TIMEOUT_FACTOR)
    return min(timeout, _CHAPTER_TIMEOUT_MAX)


def _collect_resumable_job_entries() -> list[dict]:
    summaries: dict[str, dict] = {}
    for entry in job_manager.get_resumable_jobs():
        summaries[entry["jobId"]] = entry
    for job_id, job_data in jobs.items():
        if not job_data:
            continue
        state = job_data.get("state", "")
        if state not in {"queued", "running", "cancelling", "interrupted"}:
            continue
        summaries[job_id] = _summarize_resume_job(job_id, job_data)
    return sorted(summaries.values(), key=lambda entry: entry.get("savedAt", ""), reverse=True)


_EVENT_PREFIXES = (
    "⚠️", "✅", "🔄", "🔗", "🎯", "📝", "🚀", "🔧", "📚", "📜",
    "✍️", "🔁", "🖼️", "📦", "☁️", "ℹ️", "⏱️", "🔁", "🛑", "❌", "📊",
    "🎙️", "🗣️", "🔄", "⚡", "↳", "🔒", "📦", "📁"
)


def _sanitize_event_message(message: str) -> str:
    for prefix in _EVENT_PREFIXES:
        if message.startswith(prefix):
            return message[len(prefix):].strip()
    return message


def _append_event(job: dict, message: str, *, raw: Optional[str] = None) -> None:
    events = job.setdefault("events", [])
    events.append(message)
    raw_log = job.setdefault("_raw_log", [])
    plain = raw if raw is not None else _sanitize_event_message(message)
    timestamp = datetime.utcnow().strftime("%H:%M:%S")
    raw_log.append(f"{timestamp} {plain}")

    # **OPTIMIZATION #3**: Broadcast event to SSE clients
    job_id = job.get("jobId")
    if job_id and job_id in _sse_clients:
        asyncio.create_task(_broadcast_sse_event(job_id, job))


async def _broadcast_sse_event(job_id: str, job_data: dict) -> None:
    """**OPTIMIZATION #3**: Broadcast job update to all SSE clients."""
    if job_id not in _sse_clients:
        return

    payload = _job_status_payload(job_data)
    dead_queues = set()

    for queue in _sse_clients[job_id]:
        try:
            queue.put_nowait(payload)
        except asyncio.QueueFull:
            # Client is slow, disconnect them
            dead_queues.add(queue)
        except Exception:
            dead_queues.add(queue)

    # Clean up disconnected clients
    if dead_queues:
        _sse_clients[job_id] -= dead_queues
        if not _sse_clients[job_id]:
            del _sse_clients[job_id]


def _job_status_payload(job_data: dict) -> dict:
    payload = dict(job_data)
    payload["rawLog"] = job_data.get("_raw_log", [])
    payload.pop("_raw_log", None)
    return payload


def _summarize_recent_job(job_id: str, job_data: dict, saved_at: Optional[str] = None) -> dict:
    outputs = job_data.get("outputs") or []
    zip_asset = None
    for asset in outputs:
        name = (asset.get("name") or "").lower()
        if name.endswith(".zip"):
            zip_asset = asset
            break
    resume_states = {"queued", "running", "cancelling"}
    return {
        "jobId": job_id,
        "state": job_data.get("state", "unknown"),
        "bookTitle": job_data.get("bookTitle", "Livro Desconhecido"),
        "fileName": Path(job_data.get("file_path", "")).name if job_data.get("file_path") else "unknown",
        "savedAt": saved_at or job_data.get("_saved_at") or "",
        "chaptersCompleted": job_data.get("chaptersCompleted"),
        "chaptersTotal": job_data.get("chaptersTotal"),
        "progressPercent": job_data.get("progressPercent"),
        "downloadUrl": zip_asset.get("url") if zip_asset else None,
        "hasOutputs": bool(outputs),
        "canResume": job_data.get("state") in resume_states,
        "outputs": outputs,
        "engine": job_data.get("engine"),
        "voice": job_data.get("voice"),
        "language": job_data.get("detectedLanguage") or job_data.get("language"),
        "formattingCues": job_data.get("formattingCues"),
        "uiLanguage": job_data.get("uiLanguage"),
    }


def _collect_recent_job_entries(limit: int = 10) -> list[dict]:
    """**OPTIMIZED**: Uses in-memory index to avoid reading ALL jobs from disk.

    Old approach: O(n) disk reads for n jobs
    New approach: O(1) index lookup + O(limit) disk reads for top jobs only
    """
    # **OPTIMIZATION #1**: Sort by index first (no disk I/O)
    sorted_job_ids = sorted(
        _recent_jobs_index.keys(),
        key=lambda jid: _recent_jobs_index[jid][0],  # Sort by savedAt timestamp
        reverse=True
    )

    # **OPTIMIZATION #1**: Only load top `limit` jobs
    summaries: list[dict] = []
    for job_id in sorted_job_ids[:limit]:
        # Check in-memory jobs first
        if job_id in jobs:
            job_data = jobs[job_id]
            saved_at = job_data.get("createdAt") or job_data.get("startedAt")
        else:
            # Fall back to disk/cache (rare)
            job_data = job_manager.load_job(job_id)
            if not job_data:
                continue
            saved_at = job_data.get("createdAt") or job_data.get("startedAt")

        summaries.append(_summarize_recent_job(job_id, job_data, saved_at=saved_at))

    return summaries


def _format_duration(seconds: float) -> str:
    """Return a ddhhmmss human readable duration."""
    total = max(0, int(seconds or 0))
    days, rem = divmod(total, 86400)
    hours, rem = divmod(rem, 3600)
    minutes, secs = divmod(rem, 60)
    parts: list[str] = []
    if days:
        parts.append(f"{days}d")
    if hours or days:
        parts.append(f"{hours}h")
    if minutes or hours or days:
        parts.append(f"{minutes}m")
    parts.append(f"{secs}s")
    return " ".join(parts)


def _format_hms(seconds: float) -> str:
    total = max(0, int(seconds or 0))
    hours, rem = divmod(total, 3600)
    minutes, secs = divmod(rem, 60)
    parts: list[str] = []
    if hours:
        parts.append(f"{hours:02d}h")
    if minutes or hours:
        parts.append(f"{minutes:02d}m")
    parts.append(f"{secs:02d}s")
    return " ".join(parts)


def _ensure_job(job_id: str) -> dict:
    job = jobs.get(job_id)
    if job:
        return job
    job_data = job_manager.load_job(job_id)
    if not job_data:
        raise HTTPException(status_code=404, detail="Job not found")
    jobs[job_id] = job_data
    return job_data


def _enqueue_job(job_id: str) -> bool:
    """Queue a job for processing via workers. Returns False if queue unavailable."""
    queue = _job_queue
    if queue is None:
        return False
    if job_id in _jobs_in_queue:
        return True
    try:
        queue.put_nowait(job_id)
        _jobs_in_queue.add(job_id)
        return True
    except asyncio.QueueFull:  # pragma: no cover - defensive
        logger.warning("Job queue is full, cannot enqueue %s", job_id)
        return False


async def _job_worker(worker_id: int) -> None:
    """Dedicated worker that processes jobs from the global queue."""
    assert _job_queue is not None
    while True:
        job_id = await _job_queue.get()
        _jobs_in_queue.discard(job_id)
        try:
            job = jobs.get(job_id) or job_manager.load_job(job_id)
            if not job:
                continue
            jobs[job_id] = job
            state = job.get("state", "")
            if state in {"finished", "cancelled"}:
                continue
            logger.info("Worker %s converting job %s (%s)", worker_id, job_id, state or "queued")
            await process_conversion(job_id)
        except Exception as exc:  # pragma: no cover - defensive
            logger.error("Worker %s failed processing job %s: %s", worker_id, job_id, exc, exc_info=True)
        finally:
            _job_queue.task_done()


async def _resume_pending_jobs() -> None:
    """Re-enqueue jobs that were running/queued before a restart."""
    await asyncio.sleep(0.1)
    for job_id, job in list(jobs.items()):
        state = job.get("state", "")
        if state not in {"queued", "running", "cancelling"}:
            continue
        file_path = Path(job.get("file_path") or "")
        if not file_path.exists():
            job["state"] = "interrupted"
            job["error"] = "Arquivo de origem foi perdido após reinício do servidor"
            _append_event(job, "❌ Arquivo temporário não encontrado - envie o EPUB novamente")
            _persist_job(job_id, force=True)
            continue
        job["state"] = "queued"
        job["resumeRequested"] = True
        _append_event(job, "♻️ Conversão retomada após reinício do servidor")
        _persist_job(job_id, force=True)
        if not _enqueue_job(job_id):
            logger.warning("Job queue unavailable during resume, executing inline for %s", job_id)
            asyncio.create_task(process_conversion(job_id))

# Load existing jobs from disk on startup
jobs: Dict[str, dict] = job_manager.load_all_jobs()
logger.info(f"Loaded {len(jobs)} jobs from disk")

# **OPTIMIZATION #1**: Create lightweight index for recent jobs API
# Maps job_id -> (savedAt timestamp, bookTitle) for fast sorting without loading full job data
_recent_jobs_index: Dict[str, tuple[str, str]] = {}

# **OPTIMIZATION #1**: Populate index from loaded jobs
for job_id, job_data in jobs.items():
    saved_at = job_data.get("createdAt") or job_data.get("startedAt") or datetime.utcnow().isoformat()
    book_title = job_data.get("bookTitle") or "Unknown"
    _recent_jobs_index[job_id] = (saved_at, book_title)

# **OPTIMIZATION #3**: Server-Sent Events (SSE) support
# Maps job_id -> set of asyncio queues for SSE clients
_sse_clients: Dict[str, set[asyncio.Queue]] = {}

# Auto-detect hardware and optimize
from src.hardware_detector import HardwareDetector
_hardware_profile = HardwareDetector.detect()
HardwareDetector.apply_optimizations(_hardware_profile)
logger.info(f"Hardware auto-detected: {_hardware_profile.performance_tier} tier, "
           f"EDGE_MAX_CONCURRENCY={_hardware_profile.recommended_concurrency}")

try:
    _PARALLEL_SLOTS_DEFAULT = max(
        1,
        int(
            os.getenv("CHAPTER_PARALLEL_COUNT")
            or getattr(_hardware_profile, "recommended_chapter_parallel", 1)
            or 1
        ),
    )
except (TypeError, ValueError):
    _PARALLEL_SLOTS_DEFAULT = max(1, getattr(_hardware_profile, "recommended_chapter_parallel", 1) or 1)

# Background task for periodic job cleanup
_cleanup_task: Optional[asyncio.Task] = None


async def _periodic_job_cleanup():
    """Periodically clean up old completed jobs."""
    while True:
        try:
            await asyncio.sleep(CLEANUP_INTERVAL_SECONDS)

            current_time = time.time()
            jobs_to_remove = []

            for job_id, job_data in list(jobs.items()):
                state = job_data.get("state")
                completed_at = job_data.get("completedAt")

                # Only cleanup finished/failed jobs
                if state in ("finished", "failed", "cancelled"):
                    if completed_at:
                        # Check if job is older than TTL
                        age_hours = (current_time - completed_at) / 3600
                        if age_hours > COMPLETED_JOB_TTL_HOURS:
                            jobs_to_remove.append(job_id)
                    elif state == "finished":
                        # Old finished jobs without timestamp - remove after 1 hour since server start
                        # This handles jobs from before this fix
                        jobs_to_remove.append(job_id)

            if jobs_to_remove:
                logger.info(f"Cleaning up {len(jobs_to_remove)} old jobs")
                for job_id in jobs_to_remove:
                    # Remove from memory
                    jobs.pop(job_id, None)
                    # Remove from disk
                    job_manager.delete_job(job_id)
                    # Cleanup output files
                    _cleanup_job_output(job_id)
                    logger.info(f"Cleaned up job {job_id}")

        except Exception as e:
            logger.error(f"Error in periodic job cleanup: {e}", exc_info=True)


@app.on_event("startup")
async def startup_event():
    """Start background cleanup task."""
    global _cleanup_task, _job_queue, _job_workers
    _job_queue = asyncio.Queue()
    _job_workers = [asyncio.create_task(_job_worker(idx + 1)) for idx in range(_JOB_WORKERS)]
    _cleanup_task = asyncio.create_task(_periodic_job_cleanup())
    asyncio.create_task(_resume_pending_jobs())
    logger.info("Started periodic job cleanup task")


@app.on_event("shutdown")
async def shutdown_event():
    """Stop background cleanup task."""
    global _cleanup_task, _job_queue, _job_workers
    if _cleanup_task:
        _cleanup_task.cancel()
        try:
            await _cleanup_task
        except asyncio.CancelledError:
            pass
    logger.info("Stopped periodic job cleanup task")
    for worker in list(_job_workers):
        worker.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await worker
    _job_workers.clear()
    _job_queue = None

# Mark jobs as interrupted if they were running/queued (server restart)
# IMPORTANT: On HF Spaces, /tmp is cleared on restart, so source files are lost.
# Jobs that were in progress cannot be resumed without the source file.
# Future enhancement: Save EPUB to R2 for resume capability.
for job_id, job_data in jobs.items():
    state = job_data.get("state", "")
    job_data.setdefault("cancelRequested", False)
    if state in ("queued", "running"):
        # Check if the source file still exists
        file_path = job_data.get("file_path")
        if file_path and not Path(file_path).exists():
            # Source file was lost (server restart), mark as interrupted
            job_data["state"] = "interrupted"
            job_data["error"] = "Conversão interrompida (servidor reiniciado e arquivo temporário perdido)"
            job_data["events"] = job_data.get("events", []) + [
                "",
                "⚠️ Conversão interrompida devido a reinício do servidor",
                "❌ Arquivo de origem foi perdido - não é possível retomar",
                "ℹ️ Para evitar isso, aguarde a conversão completa antes de sair",
            ]
            job_manager.save_job(job_id, job_data)
            logger.warning(f"Job {job_id} marked as interrupted (source file lost)")

tts_factory = TTSFactory()
telemetry = TelemetryRecorder()
MAX_UPLOAD_MB = int(os.getenv("MAX_UPLOAD_MB", "100"))
MAX_UPLOAD_BYTES = MAX_UPLOAD_MB * 1024 * 1024


def _normalise_languages(primary_language: Optional[str], languages: Optional[list[str]] = None) -> list[str]:
    values: list[str] = []
    if languages:
        for lang in languages:
            clean = (lang or "").strip()
            if clean:
                values.append(clean)
    primary = (primary_language or "").strip()
    if primary and primary.lower() != "auto":
        values.insert(0, primary)
    normalised: list[str] = []
    for lang in values:
        if lang not in normalised:
            normalised.append(lang)
    return normalised


def _ensure_voice_and_languages(config: ConversionConfig) -> None:
    languages = _normalise_languages(config.primary_language, config.languages)
    config.languages = languages
    provider = tts_factory.voice_provider
    fallback_voice = config.voice or provider.get_voice(config.engine, config.primary_language)
    if (config.engine or "").lower() == "coqui" and not fallback_voice:
        fallback_voice = "tts_models/multilingual/multi-dataset/xtts_v2"
    config.voice = fallback_voice
    config.language_voices = provider.build_language_voice_map(
        config.engine,
        languages,
        fallback_voice,
        primary_language=config.primary_language,
    )


def _clone_config_for_engine(base: ConversionConfig, engine_name: str) -> ConversionConfig:
    cloned = replace(base, engine=engine_name, voice=None, model_path=None)
    cloned.languages = list(base.languages)
    cloned.language_voices = {}
    _ensure_voice_and_languages(cloned)
    return cloned


def _build_engine_chain(config: ConversionConfig) -> list[ConversionConfig]:
    _ensure_voice_and_languages(config)
    chain = [config]

    def _rank_fallbacks(candidates: list[str]) -> list[str]:
        summary = telemetry.summary()
        ranked = sorted(
            ((name, summary.get(name, {}).get("avg_chars_per_second", 0.0)) for name in candidates),
            key=lambda item: item[1],
            reverse=True,
        )
        ordered = [name for name, _ in ranked if name in candidates]
        for name in candidates:
            if name not in ordered:
                ordered.append(name)
        return ordered

    if (config.engine or "").lower() == "edge":
        fallback_engines = _rank_fallbacks(["coqui", "piper"])
        for engine_name in fallback_engines:
            clone = _clone_config_for_engine(config, engine_name)
            if clone.engine.lower() == "edge":
                clone.edge_aggressive_mode = True
            chain.append(clone)
    return chain


def _prepare_auto_engine_pool(config: ConversionConfig) -> dict[str, tuple[ConversionConfig, object]]:
    pool: dict[str, tuple[ConversionConfig, object]] = {}
    for name in ("coqui", "edge"):
        try:
            candidate = _clone_config_for_engine(config, name)
            engine_instance = tts_factory.create_engine(candidate)
            pool[name] = (candidate, engine_instance)
        except Exception:
            continue
    return pool


def _pick_auto_engine(
    chapter_chars: int,
    estimated_seconds: float,
    pool: dict[str, tuple[ConversionConfig, object]],
    telemetry_speeds: Optional[Dict[str, float]] = None,
    preferred_engine: Optional[str] = None,
) -> tuple[str, list[str]]:
    def append(order: list[str], candidate: str) -> None:
        if candidate in pool and candidate not in order:
            order.append(candidate)

    # Ordem do mais rápido para mais lento: edge > coqui
    # Testado com 3053 chars: edge=21s (144 chars/s), coqui=113s (26 chars/s)
    # Piper removido do modo automático por qualidade inferior
    order: list[str] = []
    if telemetry_speeds:
        ranked = sorted(
            ((name, telemetry_speeds.get(name, 0.0)) for name in pool.keys()),
            key=lambda item: item[1],
            reverse=True,
        )
        for name, _ in ranked:
            append(order, name)
    else:
        append(order, "edge")
        append(order, "coqui")

    for name in pool.keys():
        append(order, name)

    if not order:
        order = list(pool.keys())
    # Always prefer Edge when telemetry data is not guiding a different choice
    if not telemetry_speeds and "edge" in order:
        order = ["edge"] + [name for name in order if name != "edge"]
    if preferred_engine:
        normalized = preferred_engine.lower()
        if normalized in order:
            order = [normalized] + [name for name in order if name != normalized]

    selected = order[0]
    return selected, order


def _resolve_auto_preferred_engine(config: ConversionConfig) -> Optional[str]:
    primary = (config.primary_language or "").lower()
    if primary.startswith("pt"):
        return "edge"
    return None


def _next_auto_engine(order: list[str], attempted: set[str], pool: dict[str, tuple[ConversionConfig, object]]) -> Optional[str]:
    for name in order:
        if name in pool and name not in attempted:
            return name
    return None




class JobStatus(BaseModel):
    jobId: str
    state: str
    events: list[str] = []
    rawLog: list[str] = []
    detectedLanguage: Optional[str] = None
    chaptersTotal: Optional[int] = None
    chaptersCompleted: Optional[int] = None
    currentChapter: Optional[str] = None
    progressPercent: Optional[float] = None
    chapterProgress: Optional[list[dict]] = None
    totalSegments: Optional[int] = None
    completedSegments: Optional[int] = None
    outputs: list[dict] = []
    error: Optional[str] = None
    bookTitle: Optional[str] = None
    bookAuthor: Optional[str] = None
    coverUrl: Optional[str] = None
    coverMimeType: Optional[str] = None
    logUrl: Optional[str] = None
    parallelSlots: Optional[int] = None
    parallelActive: Optional[int] = None
    statusHint: Optional[str] = None
    engine: Optional[str] = None
    voice: Optional[str] = None
    language: Optional[str] = None
    formattingCues: Optional[bool] = None
    uiLanguage: Optional[str] = None


@app.post("/api/convert")
async def convert_ebook(
    background_tasks: BackgroundTasks,
    file: UploadFile | None = File(None),
    upload_id: Optional[str] = Form(None),
    engine: str = Form("auto"),
    voice: Optional[str] = Form(None),
    chapters: Optional[str] = Form(None),
    footnote_mode: Optional[str] = Form("inline"),
    language: Optional[str] = Form(None),
    priority: Optional[str] = Form(None),
    formatting_cues: Optional[str] = Form("on"),
    ui_language: Optional[str] = Form(None),
) -> dict[str, str]:
    speak_cues = _parse_form_bool(formatting_cues, True)
    ui_lang = _normalize_locale(ui_language, "pt")
    reuse_upload = None
    job_input_dir = None
    if upload_id:
        with _pending_lock:
            reuse_upload = _pending_uploads.pop(upload_id, None)
        if not reuse_upload:
            raise HTTPException(status_code=404, detail="Upload não encontrado ou expirado")
        job_id = str(uuid.uuid4())
        job_dir = output_dir / job_id
        job_dir.mkdir(parents=True, exist_ok=True)
        job_input_dir = job_inputs_dir / job_id
        job_input_dir.mkdir(parents=True, exist_ok=True)
        source_file = Path(reuse_upload["file_path"])
        file_hash = reuse_upload.get("file_hash")
        cover_name = reuse_upload.get("cover_filename")
        cover_mime = reuse_upload.get("cover_mime")
        cover_url = None
        original_name = reuse_upload.get("file_name") or source_file.name
        temp_file = job_input_dir / original_name
        shutil.move(str(source_file), temp_file)
        if cover_name:
            cover_source = Path(reuse_upload.get("cover_path") or "")
            if cover_source.exists():
                dest_cover = job_dir / cover_name
                shutil.move(str(cover_source), dest_cover)
                cover_url = f"/api/outputs/{job_id}/{cover_name}"
        upload_folder = source_file.parent
        if upload_folder.exists():
            shutil.rmtree(upload_folder, ignore_errors=True)
    else:
        if file is None:
            raise HTTPException(status_code=400, detail="Nenhum arquivo enviado")
        job_id = f"{uuid.uuid4()}"
        job_input_dir = job_inputs_dir / job_id
        job_input_dir.mkdir(parents=True, exist_ok=True)
        temp_file = job_input_dir / Path(file.filename or "ebook.epub").name
        raw_payload = await file.read()
        if MAX_UPLOAD_BYTES and len(raw_payload) > MAX_UPLOAD_BYTES:
            raise HTTPException(
                status_code=413,
                detail=f"Arquivo excede o limite de {MAX_UPLOAD_MB} MB",
            )
        with temp_file.open("wb") as buffer:
            buffer.write(raw_payload)
        file_hash = hashlib.sha1(raw_payload).hexdigest() if raw_payload else None

        cover_name = None
        cover_url = None
        cover_mime = None
        cover_blob = None
        try:
            reader_for_cover = EbookReader(str(temp_file))
            cover_blob = reader_for_cover.extract_cover_image()
            if cover_blob:
                cover_slug = FileManager.sanitize_filename(reader_for_cover.title or Path(file.filename).stem) or "capa"
                filename = f"{cover_slug}_cover{cover_blob.extension}"
                cover_path = output_dir / job_id
                cover_path.mkdir(parents=True, exist_ok=True)
                target = cover_path / filename
                target.write_bytes(cover_blob.data)
                cover_name = filename
                cover_url = f"/api/outputs/{job_id}/{filename}"
                cover_mime = cover_blob.media_type
        except Exception:
            pass

    jobs[job_id] = {
        "jobId": job_id,
        "state": "queued",
        "events": [],
        "_raw_log": [],
        "file_path": str(temp_file),
        "engine": engine,
        "voice": voice,
        "chapters": chapters,
        "footnote_mode": footnote_mode,
        "language": language,
        "priority": priority,
        "formattingCues": speak_cues,
        "uiLanguage": ui_lang,
        "outputs": [],
        "bookTitle": reuse_upload.get("book_title") if reuse_upload else None,
        "bookAuthor": reuse_upload.get("book_author") if reuse_upload else None,
        "cover": {"name": cover_name, "url": cover_url, "mimeType": cover_mime} if cover_name else None,
        "coverUrl": cover_url,
        "coverMimeType": cover_mime,
        "cancelRequested": False,
        "fileHash": file_hash,
        "parallelSlots": _PARALLEL_SLOTS_DEFAULT,
        "parallelActive": 0,
        "resumeRequested": False,
        "uploadDir": str(job_input_dir) if job_input_dir else None,
    }
    _append_event(jobs[job_id], "📚 Arquivo recebido, aguardando processamento...")

    # Persist job state to disk IMMEDIATELY before returning
    save_success = job_manager.save_job(job_id, jobs[job_id])
    if not save_success:
        logger.error(f"Failed to save job {job_id} on creation!")
        # Still continue - job is in memory
    else:
        logger.info(f"Job {job_id} created and persisted successfully")

    if not _enqueue_job(job_id):
        background_tasks.add_task(process_conversion, job_id)
    return {"jobId": job_id}


@app.post("/api/jobs/{job_id}/cancel")
async def cancel_job(job_id: str) -> dict:
    job = jobs.get(job_id)
    if job is None:
        job_data = job_manager.load_job(job_id)
        if not job_data:
            raise HTTPException(status_code=404, detail="Job not found")
        jobs[job_id] = job_data
        job = job_data

    state = job.get("state", "queued")
    if state in {"finished", "failed", "interrupted", "cancelled"}:
        return {"status": state}

    job["cancelRequested"] = True

    if state == "queued":
        _finalize_cancel(job_id, job, "🛑 Conversão cancelada antes de iniciar")
        return {"status": "cancelled"}

    if state != "cancelling":
        job["state"] = "cancelling"
        _append_event(job, "🛑 Cancelamento solicitado. Finalizando capítulo atual…")
        _persist_job(job_id, force=True)

    return {"status": job["state"]}


@app.post("/api/jobs/{job_id}/resume")
async def resume_job(job_id: str) -> dict:
    """Requeue an interrupted/failed job so it can continue conversion."""
    job = _ensure_job(job_id)
    state = job.get("state", "")
    if state == "finished":
        return {"status": "finished"}
    source_path = Path(job.get("file_path") or "")
    if not source_path.exists():
        raise HTTPException(status_code=409, detail="Arquivo de origem não está mais disponível")
    job["cancelRequested"] = False
    job["resumeRequested"] = True
    job["state"] = "queued"
    _append_event(job, "♻️ Retomando conversão a pedido do usuário")
    _persist_job(job_id, force=True)
    if not _enqueue_job(job_id):
        raise HTTPException(status_code=503, detail="Fila de processamento indisponível no momento")
    return {"status": "queued"}


@app.get("/api/outputs/{job_id}/{filename}")
async def download_output(job_id: str, filename: str) -> FileResponse:
    file_path = output_dir / job_id / filename
    if not file_path.exists():
        raise HTTPException(status_code=404, detail="File not found")
    return FileResponse(path=file_path, media_type=_guess_media_type(filename), filename=filename)


@app.post("/api/cleanup")
async def cleanup_old_files(max_age_hours: int = 48) -> dict:
    """
    Cleanup old files from local storage and R2.

    This endpoint should be called periodically (e.g., via cron job).
    """
    result = {
        "local_deleted": 0,
        "r2_deleted": 0,
        "errors": []
    }

    try:
        # Cleanup local files
        import time
        cutoff_time = time.time() - (max_age_hours * 3600)

        for job_dir in output_dir.iterdir():
            if not job_dir.is_dir():
                continue

            # Check directory age
            dir_mtime = job_dir.stat().st_mtime
            if dir_mtime < cutoff_time:
                try:
                    import shutil
                    shutil.rmtree(job_dir)
                    result["local_deleted"] += 1
                    logger.info(f"Deleted old job directory: {job_dir.name}")
                except Exception as e:
                    result["errors"].append(f"Failed to delete {job_dir.name}: {str(e)}")

        # Cleanup R2 files
        if storage.is_enabled():
            r2_deleted = storage.cleanup_old_files(max_age_hours=max_age_hours)
            result["r2_deleted"] = r2_deleted

        # Cleanup old job state files
        jobs_deleted = job_manager.cleanup_old_jobs(max_age_hours=max_age_hours)
        result["jobs_deleted"] = jobs_deleted

        logger.info(f"Cleanup completed: {result}")
        return result

    except Exception as e:
        logger.error(f"Cleanup failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/health")
async def health_check() -> dict:
    """Health check endpoint for monitoring."""
    return {
        "status": "healthy",
        "storage": {
            "r2_enabled": storage.is_enabled(),
            "local_output_dir": str(output_dir),
        },
        "limits": {
            "max_upload_bytes": MAX_UPLOAD_BYTES,
            "max_upload_mb": MAX_UPLOAD_MB,
        },
    }


@app.get("/api/jobs/resumable")
async def get_resumable_jobs() -> dict:
    """Get list of jobs that can be resumed."""
    resumable = _collect_resumable_job_entries()
    return {
        "resumable_jobs": resumable,
        "count": len(resumable)
    }


@app.get("/api/jobs/recent")
async def get_recent_jobs(limit: int = 10) -> dict:
    """Return recently saved jobs (finished or resumable)."""
    entries = _collect_recent_job_entries(limit=limit)
    return {
        "jobs": entries,
        "count": len(entries),
    }


@app.get("/api/jobs/{job_id}")
async def get_job_status(job_id: str) -> JobStatus:
    # Check in-memory jobs first
    if job_id in jobs:
        return JobStatus(**_job_status_payload(jobs[job_id]))

    # Try to load from disk if not in memory
    logger.info(f"Job {job_id} not in memory, attempting to load from disk")
    job_data = job_manager.load_job(job_id)
    if job_data:
        # Add back to memory cache for future requests
        jobs[job_id] = job_data
        logger.info(f"Job {job_id} loaded from disk successfully")
        return JobStatus(**_job_status_payload(job_data))

    # Log all available jobs for debugging
    available_jobs = list(jobs.keys())
    logger.error(f"Job {job_id} not found! Available jobs in memory: {available_jobs[:5]}...")
    raise HTTPException(status_code=404, detail=f"Job {job_id} not found")


@app.get("/api/jobs/{job_id}/stream")
async def stream_job_status(job_id: str, request: Request):
    """**OPTIMIZATION #3**: Server-Sent Events endpoint for real-time job updates.

    Usage from frontend:
        const eventSource = new EventSource(`/api/jobs/${jobId}/stream`);
        eventSource.onmessage = (event) => {
            const jobData = JSON.parse(event.data);
            // Update UI with jobData
        };
    """
    # Verify job exists
    if job_id not in jobs and not job_manager.load_job(job_id):
        raise HTTPException(status_code=404, detail=f"Job {job_id} not found")

    # Create queue for this client
    client_queue: asyncio.Queue[dict] = asyncio.Queue(maxsize=10)

    # Register client
    if job_id not in _sse_clients:
        _sse_clients[job_id] = set()
    _sse_clients[job_id].add(client_queue)

    async def event_stream():
        try:
            # Send initial state immediately
            if job_id in jobs:
                initial_data = _job_status_payload(jobs[job_id])
                yield f"data: {json.dumps(initial_data)}\n\n"

            # Stream updates
            while True:
                # Check if client disconnected
                if await request.is_disconnected():
                    break

                try:
                    # Wait for next update (with timeout to allow disconnect check)
                    job_data = await asyncio.wait_for(client_queue.get(), timeout=1.0)
                    yield f"data: {json.dumps(job_data)}\n\n"
                except asyncio.TimeoutError:
                    # Send heartbeat to keep connection alive
                    yield ": heartbeat\n\n"

        finally:
            # Unregister client
            if job_id in _sse_clients and client_queue in _sse_clients[job_id]:
                _sse_clients[job_id].remove(client_queue)
                if not _sse_clients[job_id]:
                    del _sse_clients[job_id]

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",  # Disable nginx buffering
        }
    )


@app.get("/api/uploads/{upload_id}/{filename}")
async def serve_uploaded_asset(upload_id: str, filename: str):
    path = uploads_dir / upload_id / filename
    if not path.exists():
        raise HTTPException(status_code=404, detail="Arquivo não encontrado")
    return FileResponse(str(path))


@app.post("/api/uploads")
async def upload_ebook(file: UploadFile = File(...)) -> dict:
    """Upload ebook ahead of conversion to extract metadata/cover."""
    if file is None:
        raise HTTPException(status_code=400, detail="Arquivo não enviado")

    raw_payload = await file.read()
    if MAX_UPLOAD_BYTES and len(raw_payload) > MAX_UPLOAD_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"Arquivo excede o limite de {MAX_UPLOAD_MB} MB",
        )

    _cleanup_pending_uploads()
    upload_id = f"{uuid.uuid4()}"
    upload_dir = uploads_dir / upload_id
    upload_dir.mkdir(parents=True, exist_ok=True)
    original_name = Path(file.filename or "ebook").name
    temp_path = upload_dir / original_name
    temp_path.write_bytes(raw_payload)
    file_hash = hashlib.sha1(raw_payload).hexdigest() if raw_payload else None

    book_title = Path(original_name).stem
    book_author = "Autor Desconhecido"
    cover_url = None
    cover_mime = None
    cover_filename = None
    cover_path = None

    try:
        reader = EbookReader(str(temp_path))
        if reader.title:
            book_title = reader.title
        if reader.author:
            book_author = reader.author
        cover_blob = reader.extract_cover_image()
        if cover_blob:
            cover_filename = f"cover{cover_blob.extension}"
            cover_path = upload_dir / cover_filename
            cover_path.write_bytes(cover_blob.data)
            cover_url = f"/api/uploads/{upload_id}/{cover_filename}"
            cover_mime = cover_blob.media_type

        # **OPTIMIZATION #5**: Pre-cache parsed chapters for faster conversions
        try:
            cache_manager = CacheManager()
            chapters_list = list(reader.get_chapters())
            if chapters_list:
                chapters_data = {
                    'title': book_title,
                    'author': book_author,
                    'chapters': [
                        {
                            'title': getattr(ch, 'name', f'Chapter {i}'),
                            'text': getattr(ch, 'text', '')
                        }
                        for i, ch in enumerate(chapters_list, 1)
                    ]
                }
                cache_manager.save_chapters_to_cache(temp_path, chapters_data)
        except Exception as cache_error:
            # Cache is optional, don't fail upload if it fails
            logger.warning(f"Failed to cache chapters during upload: {cache_error}")
    except Exception:
        pass

    with _pending_lock:
        _pending_uploads[upload_id] = {
            "file_path": str(temp_path),
            "file_name": original_name,
            "book_title": book_title,
            "book_author": book_author,
            "cover_filename": cover_filename,
            "cover_path": str(cover_path) if cover_path else None,
            "cover_mime": cover_mime,
            "file_hash": file_hash,
            "created_at": time.time(),
        }

    return {
        "uploadId": upload_id,
        "fileName": original_name,
        "bookTitle": book_title,
        "bookAuthor": book_author,
        "coverUrl": cover_url,
        "coverMimeType": cover_mime,
    }


@app.get("/api/voices")
async def list_available_voices() -> dict:
    """Expose curated voice/model suggestions for the frontend."""
    provider = tts_factory.voice_provider
    return {
        "voices": provider.get_voice_suggestions(),
    }


@app.get("/api/telemetry")
async def get_engine_telemetry() -> dict:
    """Return aggregated throughput data to compare Edge vs Coqui/Piper speeds."""
    summary = telemetry.summary()
    recent = [
        {
            "engine": entry.get("engine"),
            "chars": entry.get("chars"),
            "synth_seconds": entry.get("synth_seconds"),
            "timestamp": entry.get("timestamp"),
        }
        for entry in telemetry.recent_samples(limit=10)
    ]
    return {
        "engines": summary,
        "recent": recent,
    }


def _persist_job(job_id: str, force: bool = True) -> None:
    """
    Helper to persist job state to disk.

    Args:
        job_id: Job ID to persist
        force: If True, persist immediately. If False, skip (use for non-critical updates)
    """
    if job_id not in jobs:
        logger.warning(f"Cannot persist job {job_id}: not found in memory")
        return

    if not force:
        return  # Skip for non-critical updates

    success = job_manager.save_job(job_id, jobs[job_id])
    if not success:
        logger.error(f"Failed to persist job {job_id} to disk")
    else:
        # **OPTIMIZATION #1**: Update index when job is persisted
        job_data = jobs[job_id]
        saved_at = job_data.get("createdAt") or job_data.get("startedAt") or datetime.utcnow().isoformat()
        book_title = job_data.get("bookTitle") or "Unknown"
        _recent_jobs_index[job_id] = (saved_at, book_title)


def _cleanup_job_output(job_id: str) -> None:
    """Remove the job output directory."""
    job_dir = output_dir / job_id
    if job_dir.exists():
        shutil.rmtree(job_dir, ignore_errors=True)


def _clear_job_cache(job: dict) -> None:
    """Clear cached chapters/audio for this job."""
    try:
        cache_manager = CacheManager()
        source_path = Path(job.get("file_path", "")) if job.get("file_path") else None
        book_title = job.get("bookTitle")
        if source_path and source_path.exists():
            cache_manager.clear_cache(source_path, title=book_title)
        elif book_title:
            cache_manager.clear_cache(title=book_title)
    except Exception:
        pass


def _finalize_cancel(job_id: str, job: dict, note: str) -> None:
    """Mark job as cancelled and cleanup files/cache."""
    if job.get("state") == "cancelled":
        return
    current_index = job.get("_currentChapterIndex")
    if current_index:
        _set_chapter_status(job, current_index, "cancelled")
    if note:
        _append_event(job, note)
    job["parallelActive"] = 0
    _append_event(job, "🛑 Conversão cancelada pelo usuário")
    job["state"] = "cancelled"
    job["error"] = "Cancelado pelo usuário"
    job["cancelRequested"] = True
    job["resumeRequested"] = False
    job["currentChapter"] = None
    job["progressPercent"] = job.get("progressPercent") or 0.0
    job["completedAt"] = time.time()  # Timestamp for cleanup
    _persist_job(job_id, force=True)
    # KEEP cancelled jobs in memory for a while (cleanup task will remove later)
    _persist_job_log(job_id, job)


def _store_cover_in_cache(file_hash: Optional[str], cover_blob) -> Optional[Path]:
    if not file_hash or not cover_blob:
        return None
    filename = f"{file_hash}{cover_blob.extension}"
    cache_path = cover_cache_dir / filename
    try:
        cache_path.write_bytes(cover_blob.data)
        cover_cache_index[file_hash] = {
            "filename": filename,
            "mime": cover_blob.media_type,
        }
        _save_cover_cache(cover_cache_index)
        return cache_path
    except Exception:
        return None


def _persist_job_log(job_id: str, job: dict) -> Optional[Path]:
    job_dir = output_dir / job_id
    if not job_dir.exists():
        return None
    log_path = job_dir / "conversion.log"
    try:
        raw_lines = job.get("_raw_log") or job.get("events") or []
        log_path.write_text("\n".join(raw_lines), encoding="utf-8")
        job["logUrl"] = f"/api/outputs/{job_id}/{log_path.name}"
        return log_path
    except Exception:
        return None


async def process_conversion(job_id: str) -> None:
    job = jobs[job_id]
    zip_archive: Optional[zipfile.ZipFile] = None
    zip_open = False
    conversion_started = time.time()

    try:
        if job.get("cancelRequested"):
            _finalize_cancel(job_id, job, "🛑 Conversão cancelada antes de iniciar")
            return

        job["state"] = "running"
        _append_event(job, "📚 METADADOS DO EBOOK")
        _append_event(job, "=" * 64)
        _persist_job(job_id, force=True)  # Persist state change

        file_path = Path(job["file_path"])
        reader = EbookReader(str(file_path))
        cover_blob = None
        cached_cover_entry = None
        file_hash = job.get("fileHash")
        if file_hash:
            cached_cover_entry = cover_cache_index.get(file_hash)
        cached_cover_path = None
        if cached_cover_entry:
            candidate = cover_cache_dir / cached_cover_entry.get("filename", "")
            if candidate.exists():
                cached_cover_path = candidate

        if not cached_cover_path:
            cover_blob = reader.extract_cover_image()

        title = reader.title or "Livro_Desconhecido"
        author = reader.author or "Autor Desconhecido"
        job["bookTitle"] = title
        job["bookAuthor"] = author

        _append_event(job, f"📜 Título: {title}")
        _append_event(job, f"✍️ Autor: {author}")
        job["chaptersCompleted"] = 0

        _append_event(job, "")
        _append_event(job, "🌐 DETECÇÃO DE IDIOMA")
        _append_event(job, "-" * 64)
        detected_lang = job.get("language") or "pt-BR"
        job["detectedLanguage"] = detected_lang
        _append_event(job, f"🌐 Idioma principal: {detected_lang} (estimado)")
        _persist_job(job_id, force=True)  # Persist metadata

        # Create TTS engine using factory with optimized compression
        config = ConversionConfig(
            engine=job.get("engine", "edge"),
            voice=job.get("voice"),
            primary_language=detected_lang,
            output_dir=str(output_dir / job_id),
            # Optimized compression for web delivery (reduce file size & bandwidth)
            bitrate="8k",        # 8 kbps - good quality for voice, ~3.6 MB/hour
            sample_rate=16_000,  # 16 kHz - sufficient for speech
            channels=1,          # Mono - audiobooks don't need stereo
            languages=[detected_lang] if detected_lang and detected_lang.lower() != "auto" else [],
            priority_selectors=[
                token.strip() for token in re.split(r"[\s,;]+", job.get("priority") or "") if token.strip()
            ],
            speak_formatting_cues=job.get("formattingCues", True),
            formatting_locale=_normalize_locale(job.get("uiLanguage"), "pt"),
        )
        if (config.engine or "").lower() == "edge":
            # **PERFORMANCE OPTIMIZATIONS**: Enable parallel processing and larger chunks
            config.edge_aggressive_mode = False  # Disable aggressive mode (conflicts with parallel)
            config.edge_enable_parallel = True   # Enable parallel processing (5-6x faster)
            config.edge_chunk_chars = 20000      # Larger chunks (reduce overhead)
            config.edge_max_segment_seconds = 75  # Longer segments (reduce network calls)

        selector_text = job.get("chapters")
        chapters = _prepare_chapters(reader, config, selector_text)

        # Store original before deduplication for potential restoration
        original_chapters = chapters.copy()

        chapters, duplicates_removed = deduplicate_chapters_by_content(chapters)
        if duplicates_removed:
            _append_event(job, f"🧹 Capítulo duplicado detectado: {duplicates_removed} removido(s)")

        # Validate chapter count against TOC
        expected_count = getattr(reader, '_toc_expected_chapters', 0)
        if expected_count > 0 and len(chapters) != expected_count and duplicates_removed > 0:
            if len(chapters) + duplicates_removed == expected_count:
                _append_event(job, f"⚠️  VALIDAÇÃO: TOC indica {expected_count} capítulos, mas foram detectados {len(chapters)}")
                _append_event(job, f"🔄 Auto-correção: restaurando {duplicates_removed} capítulo(s) removido(s)")
                chapters = original_chapters
        try:
            _enforce_chapter_limit(len(chapters))
        except HTTPException as limit_error:
            _append_event(job, f"❌ {limit_error.detail}")
            _persist_job(job_id, force=True)
            raise
        selection_note = " (filtro aplicado)" if selector_text else ""
        _append_event(job, f"📊 Capítulos: {len(chapters)}{selection_note}")
        job["chaptersTotal"] = len(chapters)
        def _update_job_progress() -> None:
            completed = max(0, min(len(chapters), job.get("chaptersCompleted", 0)))
            job["progressPercent"] = (completed / max(len(chapters), 1)) * 100

        def _refresh_chapter_completion() -> None:
            job["chaptersCompleted"] = _count_completed_chapters()

        def _count_completed_chapters() -> int:
            entries = job.get("chapterProgress") or []
            return sum(
                1
                for entry in entries
                if isinstance(entry, dict) and entry.get("status") in {"completed", "skipped"}
            )

        chapter_progress_entries: list[dict] = []
        for idx, chapter in enumerate(chapters, 1):
            chapter_name = getattr(chapter, "name", f"Chapter {idx}")
            chapter_progress_entries.append(
                {
                    "index": idx,
                    "name": chapter_name,
                    "status": "pending",
                }
            )
        job["chapterProgress"] = chapter_progress_entries
        _refresh_chapter_completion()

        engine_chain = _build_engine_chain(config)
        engine_index = 0
        tts_engine = None
        active_config: Optional[ConversionConfig] = None
        auto_mode = (config.engine or "").lower() == "auto"

        auto_engine_pool: dict[str, tuple[ConversionConfig, object]] = {}
        telemetry_speeds: Dict[str, float] = {}
        preferred_auto_engine: Optional[str] = None

        if not auto_mode:
            while engine_index < len(engine_chain):
                candidate = engine_chain[engine_index]
                try:
                    tts_engine = tts_factory.create_engine(candidate)
                    active_config = candidate
                    break
                except ImportError as exc:
                    _append_event(job, f"⚠️ Engine '{candidate.engine}' indisponível: {exc}")
                except Exception as exc:
                    _append_event(job, f"⚠️ Falha ao iniciar engine '{candidate.engine}': {exc}")
                engine_index += 1

            if tts_engine is None or active_config is None:
                job["state"] = "failed"
                job["error"] = "Nenhuma engine TTS disponível"
                _append_event(job, "❌ Nenhuma engine TTS disponível para iniciar")
                _persist_job(job_id, force=True)
                return
        else:
            active_config = config
            auto_engine_pool = _prepare_auto_engine_pool(config)
            if not auto_engine_pool:
                job["state"] = "failed"
                job["error"] = "Nenhuma engine disponível no modo automático"
                _append_event(job, "❌ Nenhuma engine disponível no modo automático")
                _persist_job(job_id, force=True)
                return
            preferred_auto_engine = _resolve_auto_preferred_engine(config)

        _append_event(job, "")
        _append_event(job, f"🎙️ Engine: {active_config.engine}")
        _append_event(job, f"🗣️ Voz: {active_config.voice or 'padrão'}")
        parallel_slots = max(1, int(job.get("parallelSlots") or _PARALLEL_SLOTS_DEFAULT))
        job["parallelSlots"] = parallel_slots
        if parallel_slots > 1:
            _append_event(job, f"🚀 Paralelo automático: até {parallel_slots} capítulos simultâneos")
        else:
            _append_event(job, "🔄 Modo sequencial: 1 capítulo por vez")

        job_output_dir = output_dir / job_id
        resume_mode = bool(job.get("resumeRequested")) and job_output_dir.exists()

        # Preserve uploaded source file before cleaning the output directory.
        source_path_str = job.get("file_path")
        if source_path_str:
            source_path = Path(source_path_str)
            try:
                if source_path.exists() and source_path.is_relative_to(job_output_dir):
                    safe_source = output_dir / f"{job_id}_{source_path.name}"
                    safe_source.parent.mkdir(parents=True, exist_ok=True)
                    shutil.move(str(source_path), str(safe_source))
                    job["file_path"] = str(safe_source)
                    source_path = safe_source
            except ValueError:
                # Path.is_relative_to not supported for unrelated paths prior to 3.9
                pass

        # Preserve cover file (used for the preview) while resetting the directory.
        cover_restore: Optional[tuple[Path, Path]] = None
        if not resume_mode:
            cover_entry = job.get("cover") or {}
            cover_name = cover_entry.get("name")
            if cover_name:
                cover_path = job_output_dir / cover_name
                if cover_path.exists():
                    temp_cover = output_dir / f"{job_id}_{cover_name}"
                    try:
                        shutil.move(str(cover_path), str(temp_cover))
                        cover_restore = (temp_cover, cover_path)
                    except Exception:
                        cover_restore = None

            if job_output_dir.exists():
                shutil.rmtree(job_output_dir, ignore_errors=True)
            job_output_dir.mkdir(exist_ok=True)

            if cover_restore:
                temp_cover, target_cover = cover_restore
                try:
                    shutil.move(str(temp_cover), str(target_cover))
                except Exception:
                    with contextlib.suppress(FileNotFoundError):
                        temp_cover.unlink(missing_ok=True)
        else:
            job_output_dir.mkdir(exist_ok=True)
        _append_event(job, "♻️ Retomando conversão anterior - mantendo capítulos já gerados")

        book_safe_name = FileManager.sanitize_filename(title)
        zip_file = job_output_dir / f"{book_safe_name}.zip"
        zip_archive = zipfile.ZipFile(zip_file, "w", zipfile.ZIP_STORED)
        zip_open = True
        outputs: list[dict] = []
        completed_indices: set[int] = set()
        if resume_mode:
            existing_outputs, completed_indices = await _preload_existing_outputs(job, chapters, job_output_dir)
            if existing_outputs:
                outputs.extend(existing_outputs)
                _append_event(job, f"⏩ {len(existing_outputs)} capítulo(s) já estavam convertidos")
                if chapters:
                    progress = (len(completed_indices) / len(chapters)) * 100
                    job["progressPercent"] = max(job.get("progressPercent") or 0.0, progress)
                job["chaptersCompleted"] = len(completed_indices)

        if job.get("cancelRequested"):
            _finalize_cancel(job_id, job, "🛑 Conversão cancelada após processar capítulos")
            return

        if cached_cover_path:
            filename = cached_cover_path.name
            target_cover = job_output_dir / filename
            try:
                shutil.copy2(cached_cover_path, target_cover)
                cover_url = f"/api/outputs/{job_id}/{filename}"
                job["cover"] = {
                    "name": filename,
                    "url": cover_url,
                    "mimeType": cached_cover_entry.get("mime"),
                }
                job["coverUrl"] = cover_url
                job["coverMimeType"] = cached_cover_entry.get("mime")
                _append_event(job, "🖼️ Capa reutilizada do cache")
                _persist_job(job_id, force=True)
            except Exception as cover_exc:
                _append_event(job, f"⚠️ Falha ao reutilizar capa: {cover_exc}")
        elif cover_blob:
            original_name = Path(job.get("file_path", "")).name
            cover_slug = (
                FileManager.sanitize_filename(title)
                or FileManager.sanitize_filename(original_name)
                or "capa"
            )
            filename = f"{cover_slug}_cover{cover_blob.extension}"
            cover_path = job_output_dir / filename
            try:
                cover_path.write_bytes(cover_blob.data)
                _store_cover_in_cache(file_hash, cover_blob)
                cover_url = f"/api/outputs/{job_id}/{filename}"
                job["cover"] = {
                    "name": filename,
                    "url": cover_url,
                    "mimeType": cover_blob.media_type,
                }
                job["coverUrl"] = cover_url
                job["coverMimeType"] = cover_blob.media_type
                _append_event(job, "🖼️ Capa do livro detectada")
                _persist_job(job_id, force=True)
            except Exception as cover_exc:
                _append_event(job, f"⚠️ Falha ao salvar capa: {cover_exc}")
                job["cover"] = None
                job["coverUrl"] = None
                job["coverMimeType"] = None

        def _resolve_tts_output(target_mp3: Path, engine_name: str) -> tuple[Path, bool]:
            if engine_name.lower() in {"coqui", "piper"}:
                return target_mp3.with_suffix(".wav"), True
            return target_mp3, False

        def _switch_to_next_engine(reason: str) -> bool:
            nonlocal engine_index, tts_engine, active_config
            if engine_index + 1 >= len(engine_chain):
                return False
            _append_event(job, f"🔁 {reason} → tentando fallback")

            while engine_index + 1 < len(engine_chain):
                engine_index += 1
                candidate = engine_chain[engine_index]
                _append_event(job, f"   ↳ Ativando engine '{candidate.engine}'...")
                try:
                    tts_engine = tts_factory.create_engine(candidate)
                    active_config = candidate
                    _append_event(job, f"   ✅ Agora usando {candidate.engine.upper()} ({candidate.voice or 'padrão'})")
                    return True
                except ImportError as exc:
                    _append_event(job, f"   ⚠️ Engine '{candidate.engine}' indisponível: {exc}")
                except Exception as exc:
                    _append_event(job, f"   ⚠️ Falha ao iniciar '{candidate.engine}': {exc}")
            return False

        semaphore = asyncio.Semaphore(parallel_slots)
        zip_lock = asyncio.Lock()
        job_failed = {"value": False}

        async def convert_chapter(idx: int, chapter_obj) -> None:
            async with semaphore:
                if job_failed["value"] or job.get("cancelRequested"):
                    return

                chapter_name = getattr(chapter_obj, "name", f"Chapter {idx}")
                job["_currentChapterIndex"] = idx
                job["currentChapter"] = chapter_name
                job["parallelActive"] = job.get("parallelActive", 0) + 1
                job["statusHint"] = f"Capítulo {idx}/{len(chapters)}: {chapter_name}"
                start_time = time.time()
                heartbeat_stop = asyncio.Event()
                heartbeat_task: Optional[asyncio.Task] = None

                try:
                    _set_chapter_status(job, idx, "processing")
                    _append_event(job, "")
                    _append_event(job, f"🎯 Convertendo capítulo {idx}/{len(chapters)}: {chapter_name}")

                    safe_name = FileManager.sanitize_filename(chapter_name)
                    output_file = job_output_dir / f"{idx:03d} - {safe_name}.mp3"
                    chapter_text = getattr(chapter_obj, "speech_text", None) or chapter_obj.text or ""

                    if not chapter_text or not chapter_text.strip():
                        _append_event(job, "⚠️ Capítulo sem conteúdo audível, ignorado")
                        _set_chapter_status(job, idx, "skipped")
                        _refresh_chapter_completion()
                        _update_job_progress()
                        return

                    clean_text = TextFormattingProcessor.strip_inline_markdown(chapter_text)
                    preview = _build_text_preview(clean_text)
                    if preview:
                        _append_event(job, f"📝 Trecho: {preview}")
                    auto_order: list[str] = []
                    attempted_auto: set[str] = set()
                    engine_runtime: Optional[float] = None
                    local_active_config = active_config
                    local_tts_engine = tts_engine

                    if auto_mode:
                        if not telemetry_speeds:
                            summary = telemetry.summary()
                            telemetry_speeds.update({name: stats.get("avg_chars_per_second", 0.0) for name, stats in summary.items()})
                        selected_engine, auto_order = _pick_auto_engine(
                            len(clean_text),
                            TextValidator.estimate_duration(clean_text),
                            auto_engine_pool,
                            telemetry_speeds=telemetry_speeds,
                            preferred_engine=preferred_auto_engine,
                        )
                        attempted_auto.add(selected_engine)
                        local_active_config, local_tts_engine = auto_engine_pool[selected_engine]
                        _append_event(job, f"⚡ AUTO: usando {selected_engine.upper()} para este capítulo")
                        est = TextValidator.estimate_duration(clean_text)
                        if est <= 0:
                            est = max(len(clean_text) / 15.0, 30.0)
                        _append_event(job, f"   ↳ Texto: {len(clean_text)} chars, estimado {_format_duration(est)}")

                    estimated_seconds = TextValidator.estimate_duration(clean_text)
                    if estimated_seconds <= 0:
                        estimated_seconds = max(len(clean_text) / 15.0, 30.0)

                    async def _chapter_heartbeat_loop() -> None:
                        try:
                            while True:
                                try:
                                    await asyncio.wait_for(
                                        heartbeat_stop.wait(),
                                        timeout=_CHAPTER_HEARTBEAT_SECONDS,
                                    )
                                    break
                                except asyncio.TimeoutError:
                                    elapsed = time.time() - start_time
                                    engine_label = (
                                        (local_active_config.engine if local_active_config else config.engine) or "auto"
                                    )
                                    in_progress = _format_hms(elapsed)
                                    remaining = max(0.0, estimated_seconds - elapsed)
                                    hint = (
                                        f"Capítulo {idx}/{len(chapters)}: {chapter_name} há {_format_duration(elapsed)}"
                                    )
                                    if remaining > 0:
                                        hint += f" • resto estimado {_format_duration(remaining)}"
                                    job["statusHint"] = hint
                                    _append_event(
                                        job,
                                        f"⏳ {chapter_name}: {in_progress} usando {engine_label.upper()}",
                                    )
                                    _persist_job(job_id, force=False)
                        finally:
                            job.pop("statusHint", None)

                    heartbeat_task = asyncio.create_task(_chapter_heartbeat_loop())

                    while True:
                        if job.get("cancelRequested"):
                            _finalize_cancel(job_id, job, f"🛑 Conversão cancelada durante o capítulo {chapter_name}")
                            return

                        tts_path, needs_transcode = _resolve_tts_output(
                            output_file,
                            local_active_config.engine if local_active_config else config.engine,
                        )
                        synth_started = time.time()
                        last_stage_timestamp = synth_started
                        chapter_timeout = _resolve_chapter_timeout(estimated_seconds)
                        try:
                            await asyncio.wait_for(
                                local_tts_engine.synthesize_async(clean_text, tts_path),
                                timeout=chapter_timeout,
                            )
                            last_stage_timestamp = time.time()
                        except asyncio.TimeoutError:
                            use_engine = (
                                local_active_config.engine if local_active_config else config.engine or "desconhecido"
                            )
                            _append_event(
                                job,
                                f"   ⚠️ {chapter_name}: tempo limite de {int(chapter_timeout)}s excedido em {use_engine}",
                            )
                            job["statusHint"] = (
                                f"Capítulo {idx}/{len(chapters)} atrasado em {use_engine.upper()} (timeout)"
                            )
                            if auto_mode:
                                next_engine = _next_auto_engine(auto_order, attempted_auto, auto_engine_pool)
                                if next_engine:
                                    attempted_auto.add(next_engine)
                                    local_active_config, local_tts_engine = auto_engine_pool[next_engine]
                                    _append_event(
                                        job,
                                        f"   ↳ AUTO: alternando para {next_engine.upper()} após timeout",
                                    )
                                    continue
                            if _switch_to_next_engine(
                                f"Sintetizador {use_engine.upper()} ficou preso por {int(chapter_timeout)}s"
                            ):
                                local_tts_engine = tts_engine
                                local_active_config = active_config
                                continue
                            if _record_chapter_failure(
                                job,
                                local_tts_engine,
                                chapter_name,
                                "tempo limite excedido",
                                chapter_index=idx,
                                fatal=False,
                            ):
                                job_failed["value"] = True
                            return
                        except Exception as exc:
                            if auto_mode:
                                next_engine = _next_auto_engine(auto_order, attempted_auto, auto_engine_pool)
                                if next_engine:
                                    attempted_auto.add(next_engine)
                                    local_active_config, local_tts_engine = auto_engine_pool[next_engine]
                                    _append_event(
                                        job,
                                        f"   ↳ AUTO: alternando para {next_engine.upper()} após erro ({exc})"
                                    )
                                    continue
                            if _switch_to_next_engine(
                                f"Engine {local_active_config.engine if local_active_config else config.engine} falhou ({exc})"
                            ):
                                local_tts_engine = tts_engine
                                local_active_config = active_config
                                continue
                            if _record_chapter_failure(
                                job,
                                local_tts_engine,
                                chapter_name,
                                exc,
                                chapter_index=idx,
                                fatal=False,
                            ):
                                job_failed["value"] = True
                            return

                        target_file = output_file
                        if needs_transcode:
                            converted = await AudioProcessor.convert_to_mp3(tts_path, output_file, bitrate=config.bitrate)
                            if not converted:
                                with contextlib.suppress(OSError):
                                    tts_path.unlink(missing_ok=True)
                                if auto_mode:
                                    next_engine = _next_auto_engine(auto_order, attempted_auto, auto_engine_pool)
                                    if next_engine:
                                        attempted_auto.add(next_engine)
                                        local_active_config, local_tts_engine = auto_engine_pool[next_engine]
                                        _append_event(
                                            job,
                                            f"   ↳ AUTO: alternando para {next_engine.upper()} após falha na conversão WAV→MP3",
                                        )
                                        continue
                                if _switch_to_next_engine("Conversão WAV→MP3 falhou"):
                                    local_tts_engine = tts_engine
                                    local_active_config = active_config
                                    continue
                                if _record_chapter_failure(
                                    job,
                                    local_tts_engine,
                                    chapter_name,
                                    "falha ao converter WAV para MP3",
                                    chapter_index=idx,
                                    fatal=False,
                                ):
                                    job_failed["value"] = True
                                return
                            with contextlib.suppress(OSError):
                                tts_path.unlink(missing_ok=True)
                            target_file = converted
                            last_stage_timestamp = time.time()

                        if not target_file.exists() or target_file.stat().st_size == 0:
                            with contextlib.suppress(OSError):
                                target_file.unlink(missing_ok=True)
                            if auto_mode:
                                next_engine = _next_auto_engine(auto_order, attempted_auto, auto_engine_pool)
                                if next_engine:
                                    attempted_auto.add(next_engine)
                                    local_active_config, local_tts_engine = auto_engine_pool[next_engine]
                                    _append_event(job, "   ↳ AUTO: áudio vazio; tentando outra engine")
                                    continue
                            if _switch_to_next_engine("Áudio vazio ou inexistente"):
                                local_tts_engine = tts_engine
                                local_active_config = active_config
                                continue
                            if _record_chapter_failure(
                                job,
                                local_tts_engine,
                                chapter_name,
                                "áudio não foi gerado pelo serviço de voz",
                                chapter_index=idx,
                                fatal=False,
                            ):
                                job_failed["value"] = True
                            return
                        break

                    engine_runtime = max((last_stage_timestamp - synth_started), 0.001)
                    duration_seconds = await _get_audio_duration(output_file)
                    chapter_elapsed = time.time() - start_time

                    _append_event(job, f"✅ Concluído: {output_file.name} (em {_format_hms(chapter_elapsed)})")

                    # Add download URL to chapter progress
                    chapter_output = {
                        "name": output_file.name,
                        "url": f"/api/outputs/{job_id}/{output_file.name}",
                        "durationSeconds": round(duration_seconds, 2),
                        "sizeBytes": output_file.stat().st_size,
                    }
                    _set_chapter_status(job, idx, "completed", download_url=chapter_output["url"])
                    _refresh_chapter_completion()
                    _update_job_progress()

                    # **OPTIMIZATION #2**: Batch persist - only persist every 5 chapters or on critical milestones
                    chapters_completed = job.get("chaptersCompleted", 0)
                    should_persist = (
                        chapters_completed % 5 == 0  # Every 5 chapters
                        or chapters_completed == len(chapters)  # Last chapter
                        or chapters_completed == 1  # First chapter
                    )
                    _persist_job(job_id, force=should_persist)

                    outputs.append(chapter_output)
                    if zip_open and output_file.exists():
                        async with zip_lock:
                            try:
                                zip_archive.write(output_file, arcname=output_file.name)
                            except Exception:
                                pass

                    telemetry.record_sample(
                        engine=(local_active_config.engine if local_active_config else config.engine),
                        voice=(local_active_config.voice if local_active_config else None),
                        chars=len(clean_text),
                        synth_seconds=engine_runtime or chapter_elapsed,
                        total_seconds=chapter_elapsed,
                        audio_seconds=duration_seconds,
                        job_id=job_id,
                        chapter=chapter_name,
                    )
                    if engine_runtime and local_active_config:
                        chars_per_second = len(clean_text) / max(engine_runtime, 0.001)
                        _append_event(job, f"⏱️ {local_active_config.engine.upper()} ≈ {chars_per_second:.1f} chars/s")
                        entry = job["chapterProgress"][idx - 1]
                        if isinstance(entry, dict):
                            entry["elapsedSeconds"] = round(chapter_elapsed, 2)
                            entry["charsPerSecond"] = round(chars_per_second, 1)
                finally:
                    heartbeat_stop.set()
                    if heartbeat_task:
                        with contextlib.suppress(asyncio.CancelledError):
                            await heartbeat_task
                    job.pop("statusHint", None)
                    job["parallelActive"] = max(job.get("parallelActive", 1) - 1, 0)

        chapter_tasks = [
            asyncio.create_task(convert_chapter(idx, chapter))
            for idx, chapter in enumerate(chapters, 1)
            if idx not in completed_indices
        ]
        if chapter_tasks:
            await asyncio.gather(*chapter_tasks)

        _cleanup_output_directory(job_output_dir)

        if job.get("cancelRequested"):
            _finalize_cancel(job_id, job, "🛑 Conversão cancelada durante o processamento")
            return
        if job_failed["value"]:
            return
        job["_currentChapterIndex"] = None

        soft_failures: list[dict] = job.get("softFailures") or []
        if soft_failures:
            job["softFailureCount"] = len(soft_failures)
            preview = ", ".join(
                f"#{entry.get('index')} {entry.get('chapter')}"
                for entry in soft_failures[:3]
                if isinstance(entry, dict)
            )
            if len(soft_failures) > 3:
                preview += f" … (+{len(soft_failures) - 3})"
            summary_line = (
                f"⚠️ {len(soft_failures)} capítulo(s) falharam e foram pulados automaticamente."
            )
            if preview:
                summary_line += f" ({preview})"
            _append_event(job, summary_line)

        if zip_open:
            with contextlib.suppress(Exception):
                zip_archive.close()
            zip_open = False

        # Rebuild ZIP to include todos os capítulos disponíveis (inclusive retomados)
        _append_event(job, "📦 Compactando capítulos em ZIP final...")
        _persist_job(job_id, force=True)
        try:
            with zipfile.ZipFile(zip_file, "w", zipfile.ZIP_STORED) as rebuilt_zip:
                for mp3_path in sorted(job_output_dir.glob("*.mp3")):
                    if mp3_path.name.lower().startswith("tmp"):
                        continue
                    rebuilt_zip.write(mp3_path, arcname=mp3_path.name)
            _append_event(job, "✅ ZIP final pronto")
        except Exception as exc:
            _append_event(job, f"⚠️ Falha ao compactar ZIP: {exc}")

        # Atualiza tabela de outputs com os arquivos existentes (deduplica por nome)
        outputs_map: dict[str, dict] = {}
        for asset in outputs:
            outputs_map[asset["name"]] = asset
        for mp3_path in sorted(job_output_dir.glob("*.mp3")):
            if mp3_path.name.lower().startswith("tmp"):
                continue
            name = mp3_path.name
            entry = outputs_map.get(name)
            if not entry:
                entry = {
                    "name": name,
                    "url": f"/api/outputs/{job_id}/{name}",
                }
                outputs_map[name] = entry
            entry["sizeBytes"] = mp3_path.stat().st_size
        outputs = list(outputs_map.values())

        cover_entry = job.get("cover")
        upload_dir_path = Path(job.get("uploadDir") or "")
        if cover_entry and cover_entry.get("name") and upload_dir_path.exists():
            source_cover = upload_dir_path / cover_entry["name"]
            dest_cover = job_output_dir / cover_entry["name"]
            if source_cover.exists():
                with contextlib.suppress(Exception):
                    shutil.copy2(source_cover, dest_cover)
                    cover_entry["url"] = f"/api/outputs/{job_id}/{cover_entry['name']}"
                    job["coverUrl"] = cover_entry["url"]

        # Upload to R2 if configured
        if storage.is_enabled():
            _append_event(job, "")
            _append_event(job, "☁️ Enviando arquivos para storage permanente...")

            # Upload individual MP3s to R2
            for asset in outputs:
                mp3_path = job_output_dir / asset["name"]
                if mp3_path.exists():
                    result = storage.upload_file(
                        mp3_path,
                        object_key=f"{job_id}/{asset['name']}",
                        ttl_hours=48
                    )
                    if result.success:
                        asset["url"] = result.public_url  # Update to R2 URL
                        asset["r2_key"] = result.object_key
                        _append_event(job, f"  ✅ {asset['name']} → R2")
                    else:
                        _append_event(job, f"  ⚠️ {asset['name']} → fallback local")
                        # Keep local URL as fallback
                        asset["url"] = f"/api/outputs/{job_id}/{asset['name']}"

            # Upload ZIP to R2
            zip_result = storage.upload_file(
                zip_file,
                object_key=f"{job_id}/{zip_file.name}",
                ttl_hours=48
            )

            if zip_result.success:
                zip_url = zip_result.public_url
                _append_event(job, f"  ✅ {zip_file.name} → R2")
            else:
                zip_url = f"/api/outputs/{job_id}/{zip_file.name}"
                _append_event(job, f"  ⚠️ {zip_file.name} → fallback local")

            cover_entry = job.get("cover")
            if cover_entry and cover_entry.get("name"):
                cover_path = job_output_dir / cover_entry["name"]
                if cover_path.exists():
                    cover_result = storage.upload_file(
                        cover_path,
                        object_key=f"{job_id}/{cover_entry['name']}",
                        ttl_hours=48,
                    )
                    if cover_result.success:
                        cover_entry["url"] = cover_result.public_url
                        cover_entry["r2_key"] = cover_result.object_key
                        job["coverUrl"] = cover_result.public_url
                        _append_event(job, "  ✅ Capa → R2")
                    else:
                        _append_event(job, "  ⚠️ Capa → fallback local")
        else:
            # R2 not configured - use local URLs
            _append_event(job, "")
            _append_event(job, "ℹ️ R2 não configurado - arquivos salvos localmente")
            _append_event(job, "⚠️ Arquivos serão perdidos após restart do servidor")
            zip_url = f"/api/outputs/{job_id}/{zip_file.name}"

        outputs.insert(
            0,
            {
                "name": zip_file.name,
                "url": zip_url,
                "sizeBytes": zip_file.stat().st_size,
            },
        )

        log_path = _persist_job_log(job_id, job)
        if log_path and log_path.exists():
            log_entry = {
                "name": log_path.name,
                "url": f"/api/outputs/{job_id}/{log_path.name}",
                "sizeBytes": log_path.stat().st_size,
            }
            insert_index = 1 if outputs else 0
            outputs.insert(insert_index, log_entry)
            if zip_open:
                try:
                    zip_archive.write(log_path, arcname=log_path.name)
                except Exception:
                    pass

        total_elapsed = time.time() - conversion_started
        job["state"] = "finished"
        job["progressPercent"] = 100
        job["outputs"] = _sort_output_entries(outputs)
        job["completedAt"] = time.time()  # Timestamp for cleanup
        _append_event(job, "")
        _append_event(job, "✅ Conversão finalizada com sucesso")
        _append_event(job, f"⏱️ Tempo total de conversão: {_format_hms(total_elapsed)}")
        _append_event(job, f"📁 Arquivo disponível: {zip_file.name} ({len(chapters)} capítulos)")
        job["parallelActive"] = 0
        job["resumeRequested"] = False
        _persist_job(job_id)

        # KEEP job in memory and disk for at least 1 hour after completion
        # This prevents 404 errors when frontend is still polling
        # Jobs will be cleaned up by periodic cleanup task
        logger.info(f"Job {job_id} completed successfully - keeping in memory for frontend access")

    except Exception as exc:  # pragma: no cover - defensive handling
        job["state"] = "failed"
        job["error"] = str(exc)
        job["completedAt"] = time.time()  # Timestamp for cleanup
        _append_event(job, f"❌ Erro: {exc}")
        job["parallelActive"] = 0
        _persist_job(job_id)
        _persist_job_log(job_id, job)

    finally:
        with contextlib.suppress(Exception):
            if zip_archive:
                zip_archive.close()
        temp_path_str = job.get("file_path")
        if temp_path_str and job.get("state") in {"finished", "cancelled"}:
            temp_path = Path(temp_path_str)
            with contextlib.suppress(FileNotFoundError):
                temp_path.unlink()


def _guess_media_type(filename: str) -> str:
    lowered = filename.lower()
    if lowered.endswith(".mp3"):
        return "audio/mpeg"
    if lowered.endswith(".zip"):
        return "application/zip"
    return "application/octet-stream"


async def _get_audio_duration(file_path: Path) -> float:
    """Get audio duration using ffprobe (no pydub dependency)."""
    if not file_path.exists():
        return 0.0

    try:
        # Ensure static-ffmpeg is available
        try:
            import static_ffmpeg
            static_ffmpeg.add_paths()
        except ImportError:
            pass  # Use system ffprobe

        process = await asyncio.create_subprocess_exec(
            "ffprobe",
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            str(file_path),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await process.communicate()

        if process.returncode == 0 and stdout:
            return float(stdout.decode().strip())
    except Exception:
        pass

    # Fallback: estimate based on file size (rough approximation)
    return file_path.stat().st_size / 1000.0  # ~1KB per second for 8kbps


def _set_chapter_status(job: dict, chapter_index: Optional[int], status: str, download_url: Optional[str] = None) -> None:
    entries = job.get("chapterProgress")
    if not entries or chapter_index is None:
        return
    if isinstance(entries, list):
        idx = max(0, int(chapter_index) - 1)
        if idx < len(entries):
            entry = entries[idx]
            if isinstance(entry, dict):
                entry["status"] = status
                if download_url:
                    entry["downloadUrl"] = download_url
    if isinstance(entries, list):
        processing = sum(1 for entry in entries if isinstance(entry, dict) and entry.get("status") == "processing")
        job["parallelActive"] = processing


async def _preload_existing_outputs(job: dict, chapters: list, job_output_dir: Path) -> tuple[list[dict], set[int]]:
    """Detect chapters that already have audio on disk (resume support)."""
    existing_outputs: list[dict] = []
    completed_indices: set[int] = set()
    job_id = job.get("jobId")
    for idx, chapter in enumerate(chapters, 1):
        chapter_name = getattr(chapter, "name", f"Chapter {idx}")
        safe_name = FileManager.sanitize_filename(chapter_name)
        output_file = job_output_dir / f"{idx:03d} - {safe_name}.mp3"
        if not output_file.exists() or output_file.stat().st_size <= 0:
            continue
        duration = await _get_audio_duration(output_file)
        entry = {
            "name": output_file.name,
            "url": f"/api/outputs/{job_id}/{output_file.name}" if job_id else output_file.name,
            "durationSeconds": round(duration, 2),
            "sizeBytes": output_file.stat().st_size,
        }
        existing_outputs.append(entry)
        completed_indices.add(idx)
        _set_chapter_status(job, idx, "completed")
    return existing_outputs, completed_indices

def _record_chapter_failure(
    job: dict,
    tts_engine,
    chapter_name: str,
    error: object,
    chapter_index: Optional[int] = None,
    fatal: bool = True,
) -> bool:
    _set_chapter_status(job, chapter_index, "failed")
    last_error = getattr(tts_engine, "last_error", None)
    error_message = str(error) if error else "erro desconhecido"
    if isinstance(error, FileNotFoundError):
        failure_detail = last_error or "Edge TTS não criou o arquivo de áudio"
    else:
        failure_detail = last_error or error_message
    _append_event(job, "")
    _append_event(job, f"❌ Falha na síntese do capítulo '{chapter_name}': {failure_detail}")
    if error:
        error_type = getattr(error, "__class__", type(error)).__name__
    else:
        error_type = "UnknownError"

    if last_error and error_message and last_error != error_message:
        _append_event(job, f"   ↳ Erro interno ({error_type}): {error_message}")
    elif not last_error and error_message:
        _append_event(job, f"   ↳ Erro interno ({error_type}): {error_message}")
    failure_payload = {
        "chapter": chapter_name,
        "index": chapter_index,
        "detail": failure_detail,
    }
    if fatal:
        job["state"] = "failed"
        job["error"] = f"Falha na síntese do capítulo '{chapter_name}': {failure_detail}"
        job.setdefault("outputs", [])

        job_id = job.get("jobId")
        if job_id:
            _persist_job_log(job_id, job)

        _clear_job_cache(job)
    else:
        soft_failures = job.setdefault("softFailures", [])
        if isinstance(soft_failures, list):
            soft_failures.append(failure_payload)
        _append_event(job, "   ↳ Capítulo marcado como falho; seguindo para o próximo.")
    return fatal


def _cleanup_output_directory(job_output_dir: Path) -> None:
    """Remove leftover temp artifacts (Edge segments, partial files, etc.)."""
    try:
        FileManager.cleanup_temp_files(job_output_dir, "tmp*.mp3")
        FileManager.cleanup_temp_files(job_output_dir, "tmp*.wav")
        FileManager.cleanup_temp_files(job_output_dir, "*.tmp")
    except Exception:
        pass


def _prepare_chapters(reader: EbookReader, config: ConversionConfig, selectors: Optional[str] = None) -> list:
    """Mirror CLI chapter processing so output matches show-structure."""

    converter_app = ConverterApplication()
    converter_app._interactive_mode = False

    try:
        structure_items = converter_app._generate_structure_items(reader)
    except Exception:
        return reader.get_chapters()

    if not structure_items:
        return reader.get_chapters()

    if selectors:
        raw_selectors = [token.strip() for token in re.split(r"[\s,;]+", selectors) if token.strip()]
        if raw_selectors:
            try:
                filtered_items, filtered = converter_app._filter_structure_selection(structure_items, raw_selectors)
                if filtered and filtered_items:
                    structure_items = filtered_items
            except Exception:
                pass

    try:
        # Skip slow language detection in server mode for better performance
        # Language is already set via config.primary_language
        converter_app.language_profile = None

        transformed_items = converter_app._apply_text_transforms(structure_items, config, reader)
        converter_app._apply_structure_to_reader(reader, transformed_items)
        chapters = reader.get_chapter_structure(preserve_all=config.preserve_all_chapters)
        prioritized = chapters or reader.get_chapters()
        if getattr(config, "priority_selectors", None):
            prioritized = _apply_priority_order(prioritized, config.priority_selectors)
        return prioritized
    except Exception:
        fallback = reader.get_chapters()
        if getattr(config, "priority_selectors", None):
            fallback = _apply_priority_order(fallback, config.priority_selectors)
        return fallback


def _apply_priority_order(chapters: list, selectors: list[str]) -> list:
    if not selectors:
        return chapters
    prioritized: list = []
    seen: set[int] = set()
    selectors_norm = [str(sel).strip().lower() for sel in selectors if str(sel).strip()]
    for selector in selectors_norm:
        numeric_target: Optional[int] = None
        if selector.replace(".", "", 1).isdigit():
            try:
                numeric_target = int(float(selector))
            except ValueError:
                numeric_target = None
        for idx, chapter in enumerate(chapters):
            if idx in seen:
                continue
            name = (getattr(chapter, "name", None) or f"Chapter {idx + 1}").lower()
            if numeric_target is not None and (idx + 1) == numeric_target:
                prioritized.append(chapter)
                seen.add(idx)
                break
            if selector in name:
                prioritized.append(chapter)
                seen.add(idx)
                break
    if not prioritized:
        return chapters
    remaining = [chapter for idx, chapter in enumerate(chapters) if idx not in seen]
    return prioritized + remaining




def _build_text_preview(text: str, limit: int = 180) -> str:
    if not text:
        return ""
    preview = " ".join(text.split())
    if len(preview) > limit:
        preview = preview[:limit].rstrip() + "…"
    return preview


@app.get("/sample.epub")
async def download_sample_epub():
    """Serve bundled sample EPUB for quick testing via frontend."""
    for candidate in SAMPLE_BOOK_CANDIDATES:
        if candidate.exists():
            return FileResponse(
                str(candidate),
                media_type="application/epub+zip",
                filename="sample.epub",
            )
    raise HTTPException(status_code=404, detail="Sample EPUB indisponível")


if __name__ == "__main__":  # pragma: no cover - manual execution helper
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)

def _output_sort_key(entry: dict) -> tuple[int, str]:
    name = (entry.get("name") or "").lower()
    match = re.match(r"(\\d+)", name)
    if match:
        return (int(match.group(1)), name)
    return (10**9, name)


def _sort_output_entries(entries: list[dict]) -> list[dict]:
    mp3_entries: list[dict] = []
    other_entries: list[dict] = []
    for entry in entries:
        name = (entry.get("name") or "").lower()
        if name.endswith(".mp3"):
            mp3_entries.append(entry)
        else:
            other_entries.append(entry)
    mp3_entries.sort(key=_output_sort_key)
    return other_entries + mp3_entries
