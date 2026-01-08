#!/usr/bin/env python3
"""FastAPI server for converting EPUBs into spoken MP3 chapters."""

from __future__ import annotations

# **PERFORMANCE**: Aplicar otimizações de sistema ANTES de imports pesados
import os

# Auto-aceitar licença Coqui TTS (CPML não-comercial) - necessário para HF Space
os.environ.setdefault("COQUI_TOS_AGREED", "1")
# **CPU FIRST**: Forçar modo CPU em ambientes sem GPU (HF Spaces zero-GPU)
os.environ.setdefault("CUDA_VISIBLE_DEVICES", "")
os.environ.setdefault("FORCE_CUDA", "0")
os.environ.setdefault("FORCE_CPU_ONLY", "1")
os.environ.setdefault("TTS_USE_GPU", "0")

# Configurar otimizações de performance antes de qualquer import
try:
    from performance_config import apply_all_optimizations

    apply_all_optimizations()
except ImportError:
    print("⚠️ [Performance] Módulo de otimização não encontrado")

import asyncio
import contextlib
import hashlib
import json
import logging
import re
import shutil
import threading
import time
import uuid
import zipfile
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional

from fastapi import BackgroundTasks, FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, StreamingResponse
from main import ConverterApplication
from pydantic import BaseModel
from src.benchmark_profile import recommend_parallel_slots
from src.cache_manager import CacheManager
from src.chapter_utils import deduplicate_chapters_by_content
from src.config import CACHE_DIR, ConversionConfig
from src.ebook_reader import EbookReader
from src.engine_pool import JobEnginePool, ResourceSnapshot
from src.hardware_detector import HardwareDetector, HardwareProfile
from src.job_manager import JobManager
from src.language.detector import LanguageDetector
from src.paths import OUTPUT_DIR
from src.storage_manager import get_storage_manager
from src.system_monitor import SystemMonitor
from src.telemetry import TelemetryRecorder
from src.text_formatting import TextFormattingProcessor
from src.tts.edge_engine import reset_adaptive_settings
from src.tts.factory import TTSFactory
from src.utils import AudioProcessor, FileManager, TextValidator

logger = logging.getLogger(__name__)


@contextlib.asynccontextmanager
async def _lifespan(app: FastAPI):
    """Manage FastAPI lifespan without deprecated on_event hooks."""
    global \
        _cleanup_task, \
        _job_queue, \
        _job_workers, \
        _job_watchdog_task, \
        _app_loop, \
        _skip_resume_on_startup
    _app_loop = asyncio.get_running_loop()
    _job_queue = asyncio.Queue()
    _job_workers = [asyncio.create_task(_job_worker(idx + 1)) for idx in range(_JOB_WORKERS)]
    _cleanup_task = asyncio.create_task(_periodic_job_cleanup())
    restart_marker = _load_restart_marker()
    if restart_marker:
        keep_cache = bool(restart_marker.get("keep_cache"))
        keep_finished = bool(restart_marker.get("keep_finished"))
        _skip_resume_on_startup = True
        _purge_all_jobs(
            "restart cleanup",
            keep_finished=keep_finished,
            purge_cache=not keep_cache,
        )
        _clear_restart_staging_dirs()
        if not keep_finished:
            _clear_all_outputs(preserve_cache=keep_cache)
        if not keep_cache:
            _clear_all_caches()
        _clear_restart_marker()
    else:
        asyncio.create_task(_resume_pending_jobs())
    system_monitor.start()
    if not _job_watchdog_task:
        _job_watchdog_task = asyncio.create_task(_job_watchdog())

    try:
        from health_monitor import start_monitoring

        start_monitoring()
        logger.info("✅ Health Monitor iniciado")
    except Exception as e:
        logger.warning(f"⚠️ Falha ao iniciar Health Monitor: {e}")

    try:
        from auto_recovery import start_auto_recovery

        recovery = start_auto_recovery()
        recovery.set_activity_provider(_has_active_jobs)
        logger.info("✅ Auto-Recovery System iniciado")
    except Exception as e:
        logger.warning(f"⚠️ Falha ao iniciar Auto-Recovery: {e}")

    logger.info("Started periodic job cleanup task")
    try:
        yield
    finally:
        if _cleanup_task:
            _cleanup_task.cancel()
            try:
                await _cleanup_task
            except asyncio.CancelledError:
                pass
        logger.info("Stopped periodic job cleanup task")
        if _job_watchdog_task:
            _job_watchdog_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await _job_watchdog_task
            _job_watchdog_task = None
        for worker in list(_job_workers):
            worker.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await worker
        _job_workers.clear()
        _job_queue = None
        system_monitor.stop()


app = FastAPI(title="EPUB to MP3 Converter API", lifespan=_lifespan)

ROOT_DIR = Path(__file__).resolve().parents[1]
WEB_DIR = ROOT_DIR / "web"
SAMPLE_BOOK_CANDIDATES = [
    WEB_DIR / "dist" / "sample.epub",
    WEB_DIR / "public" / "sample.epub",
]

# Performance controls
# **PERFORMANCE**: Turbo mode sempre ativo para igualar CLI
FORCE_TURBO = os.getenv("FORCE_TURBO_MODE", "true").strip().lower() in {"1", "true", "yes", "on"}
TURBO_SLOT_MULTIPLIER = max(
    1, int(os.getenv("FORCE_TURBO_SLOT_MULTIPLIER", "3") or "3")
)  # 3x para igualar CLI
WORKER_MAX = max(1, int(os.getenv("JOB_WORKERS_MAX", "16") or "16"))
# **PERFORMANCE**: Usar mesmas configurações agressivas do CLI
# Desabilitar auto-tune conservador para máxima velocidade
EDGE_AUTO_TUNE = os.getenv("EDGE_AUTO_TUNE", "false").strip().lower() in {"1", "true", "yes", "on"}
EDGE_MIN_CHARS_PER_SECOND = float(os.getenv("EDGE_MIN_CHARS_PER_SECOND", "45") or "45")
EDGE_SLOW_RATIO_THRESHOLD = float(os.getenv("EDGE_SLOW_RATIO_THRESHOLD", "2.5") or "2.5")
# Research-based (Jan 2026): 8k default (safe range 3k-8k, >15k = incomplete)
EDGE_SAFE_CHUNK_CHARS = max(3000, int(os.getenv("EDGE_SAFE_CHUNK_CHARS", "8000") or "8000"))
EDGE_SAFE_MAX_SEGMENT_SECONDS = max(
    30, int(os.getenv("EDGE_SAFE_MAX_SEGMENT_SECONDS", "75") or "75")
)
# **PERFORMANCE**: Aumentar paralelismo de capítulos para igualar CLI
EDGE_SAFE_CHAPTER_PARALLEL = max(1, int(os.getenv("EDGE_SAFE_CHAPTER_PARALLEL", "8") or "8"))
EDGE_SAFE_TIMEOUT_MAX = max(90.0, float(os.getenv("EDGE_SAFE_TIMEOUT_MAX", "360") or "360"))
# **PERFORMANCE**: Caps mais agressivos para todas as redes
EDGE_AUTO_PARALLEL_CAPS = {
    "slow": max(1, int(os.getenv("EDGE_AUTO_PARALLEL_CAP_SLOW", "4") or "4")),
    "medium": max(1, int(os.getenv("EDGE_AUTO_PARALLEL_CAP_MEDIUM", "6") or "6")),
    "fast": max(1, int(os.getenv("EDGE_AUTO_PARALLEL_CAP_FAST", "8") or "8")),
    "ultra": max(1, int(os.getenv("EDGE_AUTO_PARALLEL_CAP_ULTRA", "8") or "8")),
}

# Job cleanup configuration
COMPLETED_JOB_TTL_HOURS = 1  # Keep completed jobs for 1 hour
CLEANUP_INTERVAL_SECONDS = 300  # Run cleanup every 5 minutes

# Initialize storage manager (R2)
storage = get_storage_manager()

# CORS configuration - supports both local dev and Cloudflare deployment
allowed_origins = [
    "http://localhost:5173",
    "http://127.0.0.1:5173",
    "http://localhost:3000",
    "http://127.0.0.1:3000",
    "http://localhost:8000",
    "http://127.0.0.1:8000",
    "http://localhost:7860",
    "http://127.0.0.1:7860",
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
    allow_origin_regex=r"^https?://(localhost|127\.0\.0\.1)(:\d+)?$",
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


def _parse_form_optional_bool(value: Optional[str]) -> Optional[bool]:
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    normalized = str(value).strip().lower()
    if not normalized:
        return None
    return normalized in {"1", "true", "yes", "on", "enabled"}


def _parse_form_int(
    value: Optional[str],
    *,
    min_value: Optional[int] = None,
    max_value: Optional[int] = None,
) -> Optional[int]:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    try:
        parsed = int(text)
    except (TypeError, ValueError):
        return None
    if min_value is not None:
        parsed = max(min_value, parsed)
    if max_value is not None:
        parsed = min(max_value, parsed)
    return parsed


def _parse_form_float(
    value: Optional[str],
    *,
    min_value: Optional[float] = None,
    max_value: Optional[float] = None,
) -> Optional[float]:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    try:
        parsed = float(text)
    except (TypeError, ValueError):
        return None
    if min_value is not None:
        parsed = max(min_value, parsed)
    if max_value is not None:
        parsed = min(max_value, parsed)
    return parsed


def _normalize_locale(value: Optional[str], default: str = "pt") -> str:
    locale_value = (value or default or "pt").split("-", 1)[0].lower()
    if locale_value not in {"pt", "en"}:
        locale_value = "en"
    return locale_value


def _utcnow_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


# Para deployments em cloud (HF Spaces, etc.), usa diretório persistente para sobreviver restarts
# Se OUTPUT_DIR env var estiver definida, usa ela; senão usa diretório persistente ou OUTPUT_DIR local
if os.getenv("OUTPUT_DIR"):
    output_dir = Path(os.getenv("OUTPUT_DIR"))
elif os.getenv("SPACE_ID"):  # HuggingFace Spaces - usar /data para persistência
    output_dir = Path(os.getenv("PERSISTENT_ROOT", "/data/epub-to-mp3")) / "output"
else:
    output_dir = OUTPUT_DIR

output_dir.mkdir(exist_ok=True, parents=True)
CACHE_DIR.mkdir(exist_ok=True, parents=True)

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
source_backups_dir = persistent_root / ".source_backups"
source_backups_dir.mkdir(exist_ok=True, parents=True)

# Cache persistente para textos extraídos de capítulos - sobrevive restarts
persistent_cache_dir = persistent_root / ".cache" if os.getenv("SPACE_ID") else CACHE_DIR
persistent_cache_dir.mkdir(exist_ok=True, parents=True)

# CacheManager singleton com diretório persistente
_persistent_cache_manager: Optional[CacheManager] = None


def get_cache_manager() -> CacheManager:
    """Retorna CacheManager singleton usando diretório persistente."""
    global _persistent_cache_manager
    if _persistent_cache_manager is None:
        _persistent_cache_manager = CacheManager(cache_dir=persistent_cache_dir)
    return _persistent_cache_manager


cover_cache_dir = output_dir / ".cover_cache"
cover_cache_dir.mkdir(exist_ok=True, parents=True)
cover_index_path = cover_cache_dir / "index.json"


# Helpers to resolve per-book/per-engine paths (supports legacy job-id layout)
def _book_slug(title: Optional[str], fallback: Optional[str] = None) -> str:
    base = title or fallback or "livro"
    try:
        stem = Path(base).stem if base and "." in base else base
    except Exception:
        stem = base
    return FileManager.sanitize_filename(stem)


def _engine_slug(engine: Optional[str]) -> str:
    return FileManager.sanitize_filename((engine or "edge").lower())


def _job_output_dir(job_id: str, job: Optional[dict] = None, ensure: bool = False) -> Path:
    legacy_dir = output_dir / job_id
    if ensure:
        legacy_dir.mkdir(parents=True, exist_ok=True)
        return legacy_dir
    job_data = job or jobs.get(job_id) or job_manager.load_job(job_id)

    if job_data:
        stored = job_data.get("outputDir")
        if stored:
            path = Path(stored)
            if ensure:
                path.mkdir(parents=True, exist_ok=True)
            return path

        book_title = job_data.get("bookTitle") or job_data.get("fileName") or ""
        file_name = job_data.get("file_path") or ""
        book_slug = _book_slug(book_title, file_name)
        engine_slug = _engine_slug(job_data.get("engine"))
        target = output_dir / book_slug / engine_slug

        # If legacy dir already exists with data, prefer it to avoid breaking older jobs
        if legacy_dir.exists() and any(legacy_dir.iterdir()):
            target = legacy_dir
        if ensure:
            target.mkdir(parents=True, exist_ok=True)
        job_data["outputDir"] = str(target)
        jobs[job_id] = job_data
        return target

    if ensure:
        legacy_dir.mkdir(parents=True, exist_ok=True)
    return legacy_dir


def _chapter_chunk_dir(job_id: str, chapter_index: int, ensure: bool = False) -> Path:
    base = _job_output_dir(job_id, ensure=ensure)
    target = Path(base) / "streams" / job_id / f"chapter_{int(chapter_index):04d}"
    if ensure:
        target.mkdir(parents=True, exist_ok=True)
    return target


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
_restart_marker_path = persistent_root / ".restart_marker.json"
_skip_resume_on_startup = False


def _load_restart_marker() -> Optional[dict]:
    try:
        data = json.loads(_restart_marker_path.read_text())
    except FileNotFoundError:
        return None
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def _write_restart_marker(*, keep_cache: bool, keep_finished: bool) -> None:
    payload = {
        "keep_cache": bool(keep_cache),
        "keep_finished": bool(keep_finished),
        "created_at": time.time(),
    }
    try:
        _restart_marker_path.write_text(json.dumps(payload))
    except Exception:
        pass


def _clear_restart_marker() -> None:
    with contextlib.suppress(OSError):
        _restart_marker_path.unlink(missing_ok=True)


_skip_resume_on_startup = bool(_load_restart_marker())

_JOB_WORKERS = max(1, int(os.getenv("JOB_WORKERS", "1") or "1"))  # Processar 1 livro por vez
_job_queue: Optional[asyncio.Queue[str]] = None
_job_workers: list[asyncio.Task] = []
_jobs_in_queue: set[str] = set()
_worker_scale_lock = asyncio.Lock()

_pending_uploads: Dict[str, dict] = {}
_pending_lock = threading.Lock()
_PENDING_TTL_SECONDS = 3600  # 1 hour
_PENDING_META_FILENAME = "upload.json"
_CHAPTER_HEARTBEAT_SECONDS = 45.0
_CHAPTER_TIMEOUT_FACTOR = 2.5
_CHAPTER_TIMEOUT_MIN = 120.0
_CHAPTER_TIMEOUT_MAX = 900.0
try:
    _CHAPTER_RETRY_MAX = max(0, int(os.getenv("CHAPTER_RETRY_MAX", "3") or "3"))
except (TypeError, ValueError):
    _CHAPTER_RETRY_MAX = 3
_CHAPTER_RETRY_FOREVER = True
try:
    _CHAPTER_RETRY_ROUNDS = max(0, int(os.getenv("CHAPTER_RETRY_ROUNDS", "1") or "1"))
except (TypeError, ValueError):
    _CHAPTER_RETRY_ROUNDS = 1
try:
    _CHAPTER_RETRY_BACKOFF_SECONDS = float(
        os.getenv("CHAPTER_RETRY_BACKOFF_SECONDS", "2.0") or "2.0"
    )
except (TypeError, ValueError):
    _CHAPTER_RETRY_BACKOFF_SECONDS = 2.0
_STALL_THRESHOLD_SECONDS = float(os.getenv("JOB_STALL_THRESHOLD_SECONDS", "480") or "480")
_STALL_RECHECK_SECONDS = float(os.getenv("JOB_STALL_RECHECK_SECONDS", "90") or "90")
_STALL_MAX_AUTO_RETRIES = max(0, int(os.getenv("JOB_STALL_MAX_AUTO_RETRIES", "1") or "1"))


def _env_float(name: str, default: float) -> float:
    raw = os.getenv(name, "")
    try:
        return float(raw) if raw else default
    except (TypeError, ValueError):
        return default


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name, "")
    try:
        return int(raw) if raw else default
    except (TypeError, ValueError):
        return default


_HEALTHCHECK_INTERVAL_SECONDS = _env_float("JOB_HEALTHCHECK_INTERVAL_SECONDS", 30.0)
_HEALTHCHECK_SLOW_EDGE_CPS = _env_float("JOB_HEALTHCHECK_SLOW_EDGE_CPS", EDGE_MIN_CHARS_PER_SECOND)
_HEALTHCHECK_SLOW_CPS = _env_float("JOB_HEALTHCHECK_SLOW_CPS", 30.0)
_HEALTHCHECK_HIGH_CPU = _env_float("JOB_HEALTHCHECK_HIGH_CPU_PERCENT", 85.0)
_HEALTHCHECK_HIGH_MEM = _env_float("JOB_HEALTHCHECK_HIGH_MEM_PERCENT", 85.0)
_HEALTHCHECK_OK_CPU = _env_float("JOB_HEALTHCHECK_OK_CPU_PERCENT", 75.0)
_HEALTHCHECK_OK_MEM = _env_float("JOB_HEALTHCHECK_OK_MEM_PERCENT", 80.0)
_HEALTHCHECK_SLOW_STREAK = max(1, _env_int("JOB_HEALTHCHECK_SLOW_STREAK", 2))
_app_loop: Optional[asyncio.AbstractEventLoop] = None


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
        active_ids = set(_pending_uploads.keys())
    for upload_dir in uploads_dir.iterdir():
        if not upload_dir.is_dir():
            continue
        upload_id = upload_dir.name
        if upload_id in active_ids:
            continue
        meta_path = upload_dir / _PENDING_META_FILENAME
        created_at = None
        if meta_path.exists():
            try:
                created_at = json.loads(meta_path.read_text()).get("created_at")
            except Exception:
                created_at = None
        if created_at is None:
            try:
                created_at = upload_dir.stat().st_mtime
            except OSError:
                created_at = None
        if created_at is not None and created_at < cutoff:
            expired.append(upload_id)
    for upload_id in expired:
        upload_dir = uploads_dir / upload_id
        if upload_dir.exists():
            shutil.rmtree(upload_dir, ignore_errors=True)


def _write_pending_upload_metadata(upload_dir: Path, data: dict) -> None:
    payload = {
        "file_name": data.get("file_name"),
        "book_title": data.get("book_title"),
        "book_author": data.get("book_author"),
        "cover_filename": data.get("cover_filename"),
        "cover_mime": data.get("cover_mime"),
        "file_hash": data.get("file_hash"),
        "created_at": data.get("created_at"),
    }
    try:
        (upload_dir / _PENDING_META_FILENAME).write_text(json.dumps(payload))
    except Exception:
        pass


def _load_pending_upload_from_disk(upload_id: str) -> Optional[dict]:
    upload_dir = uploads_dir / upload_id
    if not upload_dir.exists():
        return None
    meta_path = upload_dir / _PENDING_META_FILENAME
    payload: dict = {}
    if meta_path.exists():
        try:
            payload = json.loads(meta_path.read_text())
        except Exception:
            payload = {}
    cover_filename = payload.get("cover_filename")
    cover_path = upload_dir / cover_filename if cover_filename else None
    if cover_path and not cover_path.exists():
        cover_path = None

    file_name = payload.get("file_name")
    candidate = None
    if file_name:
        candidate = upload_dir / Path(file_name).name
        if not candidate.exists():
            candidate = None
    if candidate is None:
        for path in upload_dir.iterdir():
            if not path.is_file():
                continue
            if path.name == _PENDING_META_FILENAME:
                continue
            if cover_filename and path.name == cover_filename:
                continue
            candidate = path
            break
    if candidate is None or not candidate.exists():
        return None

    created_at = payload.get("created_at")
    if created_at is None:
        try:
            created_at = candidate.stat().st_mtime
        except OSError:
            created_at = time.time()

    return {
        "file_path": str(candidate),
        "file_name": file_name or candidate.name,
        "book_title": payload.get("book_title"),
        "book_author": payload.get("book_author"),
        "cover_filename": cover_filename,
        "cover_path": str(cover_path) if cover_path else None,
        "cover_mime": payload.get("cover_mime"),
        "file_hash": payload.get("file_hash"),
        "created_at": created_at,
    }


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
        "fileName": Path(job_data.get("file_path", "")).name
        if job_data.get("file_path")
        else "unknown",
        "savedAt": saved_at or job_data.get("_saved_at") or datetime.utcnow().isoformat(),
        "chaptersCompleted": job_data.get("chaptersCompleted", 0),
        "chaptersTotal": job_data.get("chaptersTotal"),
        "engine": job_data.get("engine"),
        "voice": job_data.get("voice"),
        "language": job_data.get("detectedLanguage") or job_data.get("language"),
        "formattingCues": job_data.get("formattingCues"),
        "uiLanguage": job_data.get("uiLanguage"),
    }


def _resolve_completed_iso(job_data: dict) -> Optional[str]:
    completed_iso = job_data.get("completedAtIso")
    if completed_iso:
        return completed_iso
    completed_epoch = job_data.get("completedAt")
    if completed_epoch:
        try:
            return datetime.fromtimestamp(float(completed_epoch), tz=timezone.utc).isoformat()
        except (TypeError, ValueError):
            return None
    return None


def _determine_saved_at(job_data: dict) -> str:
    return (
        _resolve_completed_iso(job_data)
        or job_data.get("_saved_at")
        or job_data.get("createdAt")
        or job_data.get("startedAt")
        or _utcnow_iso()
    )


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
    "⚠️",
    "✅",
    "🔄",
    "🔗",
    "🎯",
    "📝",
    "🚀",
    "🔧",
    "📚",
    "📜",
    "✍️",
    "🔁",
    "🖼️",
    "📦",
    "☁️",
    "ℹ️",
    "⏱️",
    "🔁",
    "🛑",
    "❌",
    "📊",
    "🎙️",
    "🗣️",
    "🔄",
    "⚡",
    "↳",
    "🔒",
    "📦",
    "📁",
)


def _sanitize_event_message(message: str) -> str:
    for prefix in _EVENT_PREFIXES:
        if message.startswith(prefix):
            return message[len(prefix) :].strip()
    return message


def _update_job_activity(job: Optional[dict], stage: Optional[str] = None) -> None:
    if not job:
        return
    now = time.time()
    job["_lastActivityTs"] = now
    if stage:
        job["_lastStage"] = stage


def _append_event(job: dict, message: str, *, raw: Optional[str] = None) -> None:
    events = job.setdefault("events", [])
    events.append(message)
    raw_log = job.setdefault("_raw_log", [])
    plain = raw if raw is not None else _sanitize_event_message(message)
    timestamp = datetime.utcnow().strftime("%H:%M:%S")
    raw_log.append(f"{timestamp} {plain}")

    # **OPTIMIZATION #3**: Broadcast event to SSE clients
    _schedule_job_broadcast(job.get("jobId"), job)
    _update_job_activity(job)


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


def _schedule_job_broadcast(job_id: Optional[str], job_data: Optional[dict]) -> None:
    """Dispatch job updates to SSE listeners even from worker threads."""
    if not job_id or not job_data:
        return
    if job_id not in _sse_clients:
        return
    try:
        loop = asyncio.get_running_loop()
        loop.create_task(_broadcast_sse_event(job_id, job_data))
        return
    except RuntimeError:
        pass

    if _app_loop is None or _app_loop.is_closed():
        return

    def _dispatch() -> None:
        _app_loop.create_task(_broadcast_sse_event(job_id, job_data))

    _app_loop.call_soon_threadsafe(_dispatch)


def _job_status_payload(job_data: dict) -> dict:
    payload = dict(job_data)
    payload["rawLog"] = job_data.get("_raw_log", [])
    payload.pop("_raw_log", None)
    payload["lastActivityAt"] = job_data.get("_lastActivityTs")
    return payload


def _resolve_job_activity_timestamp(job_data: dict) -> Optional[float]:
    ts = job_data.get("_lastActivityTs")
    if isinstance(ts, (int, float)):
        return float(ts)
    started_at = job_data.get("startedAt")
    if started_at:
        try:
            return datetime.fromisoformat(started_at.replace("Z", "+00:00")).timestamp()
        except ValueError:
            return None
    return None


def _summarize_recent_job(job_id: str, job_data: dict, saved_at: Optional[str] = None) -> dict:
    outputs = job_data.get("outputs") or []
    zip_asset = None
    for asset in outputs:
        name = (asset.get("name") or "").lower()
        if name.endswith(".zip"):
            zip_asset = asset
            break
    resume_states = {"queued", "running", "cancelling"}
    completed_iso = _resolve_completed_iso(job_data)
    saved_value = saved_at or _determine_saved_at(job_data)
    return {
        "jobId": job_id,
        "state": job_data.get("state", "unknown"),
        "bookTitle": job_data.get("bookTitle", "Livro Desconhecido"),
        "fileName": Path(job_data.get("file_path", "")).name
        if job_data.get("file_path")
        else "unknown",
        "savedAt": saved_value,
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
        "completedAt": completed_iso or saved_value,
        "startedAt": job_data.get("startedAt"),
        "totalDurationSeconds": job_data.get("totalElapsedSeconds"),
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
        reverse=True,
    )

    # **OPTIMIZATION #1**: Only load top `limit` jobs
    summaries: list[dict] = []
    for job_id in sorted_job_ids[:limit]:
        # Check in-memory jobs first
        if job_id in jobs:
            job_data = jobs[job_id]
            saved_at = _determine_saved_at(job_data)
        else:
            # Fall back to disk/cache (rare)
            job_data = job_manager.load_job(job_id)
            if not job_data:
                continue
            saved_at = _determine_saved_at(job_data)

        if (job_data.get("state") or "").lower() == "cancelled":
            continue

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
            logger.error(
                "Worker %s failed processing job %s: %s", worker_id, job_id, exc, exc_info=True
            )
            try:
                job = jobs.get(job_id) or job_manager.load_job(job_id)
                if job is not None:
                    job["state"] = "failed"
                    job["error"] = str(exc)
                    job["resumeRequested"] = False
                    job["cancelRequested"] = False
                    job["parallelActive"] = 0
                    job["completedAt"] = time.time()
                    _append_event(job, f"❌ Falha interna durante a conversão: {exc}")
                    _persist_job(job_id, force=True)
                    jobs[job_id] = job
            except Exception:  # pragma: no cover - defensive
                logger.exception("Failed to mark job %s as failed after worker crash", job_id)
        finally:
            _job_queue.task_done()


async def _resume_pending_jobs() -> None:
    """Re-enqueue jobs that were running/queued before a restart."""
    if _skip_resume_on_startup:
        return
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
    state = (job_data.get("state") or "").lower()
    if state == "cancelled":
        continue
    saved_at = _determine_saved_at(job_data)
    book_title = job_data.get("bookTitle") or "Unknown"
    _recent_jobs_index[job_id] = (saved_at, book_title)

# **OPTIMIZATION #3**: Server-Sent Events (SSE) support
# Maps job_id -> set of asyncio queues for SSE clients
_sse_clients: Dict[str, set[asyncio.Queue]] = {}

# Auto-detect hardware and optimize
_hardware_profile = HardwareDetector.detect()
HardwareDetector.apply_optimizations(_hardware_profile)


def _infer_perf_profile(hw: HardwareProfile, choice: str, is_space: bool) -> str:
    """Infer performance profile automatically (HF vs local vs CLI)."""
    if choice in {"hf", "local", "cli"}:
        return choice
    if is_space:
        return "hf"
    # Small CPUs behave like HF; bigger boxes can run CLI mode safely
    if (hw.cpu_physical or 0) <= 4 and not hw.has_gpu:
        return "local"
    return "cli"


def _set_default(name: str, value: str) -> None:
    if not os.getenv(name):
        os.environ[name] = value


def _apply_perf_defaults(profile: str, hw: HardwareProfile) -> None:
    """Auto-apply sane defaults per profile without overriding explicit envs."""
    if profile == "hf":
        _set_default("EDGE_MAX_CONCURRENCY", "2")
        _set_default("EDGE_MAX_CONCURRENCY_CAP", "3")
        _set_default("CHAPTER_PARALLEL_COUNT", "1")
        _set_default("CHAPTER_PARALLEL_MAX", "2")
        _set_default("EDGE_CHUNK_CHARS", "9000")
        _set_default("EDGE_MAX_SEGMENT_SECONDS", "60")
        _set_default("EDGE_ENABLE_PARALLEL", "true")
        _set_default("COQUI_MAX_WORKERS", "2")
        _set_default("PIPER_MAX_PROCS", "1")
    elif profile == "cli":
        # Favor throughput on multi-core hosts while keeping caps sane
        edge_cap = max(4, min(8, (hw.cpu_physical or 2) * 2))
        _set_default("EDGE_MAX_CONCURRENCY", str(min(6, edge_cap)))
        _set_default("EDGE_MAX_CONCURRENCY_CAP", str(edge_cap))
        _set_default("CHAPTER_PARALLEL_COUNT", str(min(4, max(2, (hw.cpu_physical or 2) // 2 + 1))))
        _set_default("CHAPTER_PARALLEL_MAX", str(min(6, (hw.cpu_physical or 2) * 2)))
        _set_default("EDGE_CHUNK_CHARS", "11000")
        _set_default("EDGE_MAX_SEGMENT_SECONDS", "75")
        _set_default("EDGE_ENABLE_PARALLEL", "true")
        _set_default("COQUI_MAX_WORKERS", str(min(8, max(4, (hw.cpu_physical or 2) * 2))))
        _set_default("PIPER_MAX_PROCS", str(min(4, max(2, (hw.cpu_physical or 2) // 2 + 1))))
    else:  # local (balanced default)
        edge_cap = max(3, min(6, (hw.cpu_physical or 2) + 2))
        _set_default("EDGE_MAX_CONCURRENCY", str(edge_cap - 1))
        _set_default("EDGE_MAX_CONCURRENCY_CAP", str(edge_cap))
        _set_default("CHAPTER_PARALLEL_COUNT", "2")
        _set_default("CHAPTER_PARALLEL_MAX", "3")
        _set_default("EDGE_CHUNK_CHARS", "10000")
        _set_default("EDGE_MAX_SEGMENT_SECONDS", "70")
        _set_default("EDGE_ENABLE_PARALLEL", "true")
        _set_default("COQUI_MAX_WORKERS", str(min(6, max(3, (hw.cpu_physical or 2)))))
        _set_default("PIPER_MAX_PROCS", "2")


# Performance profile (auto = HF-safe on Spaces, local otherwise)
_perf_profile_env = (os.getenv("PERF_PROFILE") or "auto").strip().lower()
if _perf_profile_env not in {"auto", "hf", "local", "cli"}:
    _perf_profile_env = "auto"
_perf_profile = _infer_perf_profile(
    _hardware_profile, _perf_profile_env, bool(os.getenv("SPACE_ID"))
)
_apply_perf_defaults(_perf_profile, _hardware_profile)

# Research-based: 4 concurrent default (safe: 2-4, >8 causes 403)
edge_recommended = max(2, min(6, int(_hardware_profile.recommended_concurrency or 4)))
if _perf_profile == "hf":
    edge_recommended = min(edge_recommended, 3)
elif _perf_profile == "cli":
    edge_recommended = min(8, max(edge_recommended, (_hardware_profile.cpu_physical or 2) * 2))
if FORCE_TURBO:
    edge_recommended = max(
        edge_recommended, (_hardware_profile.cpu_physical or 2) * TURBO_SLOT_MULTIPLIER
    )
if not os.getenv("EDGE_MAX_CONCURRENCY"):
    os.environ["EDGE_MAX_CONCURRENCY"] = str(edge_recommended)
logger.info(
    f"Hardware auto-detected: {_hardware_profile.performance_tier} tier, "
    f"EDGE_MAX_CONCURRENCY={os.getenv('EDGE_MAX_CONCURRENCY')} "
    f"{'(turbo mode)' if FORCE_TURBO else ''} (perf_profile={_perf_profile})"
)

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
    _PARALLEL_SLOTS_DEFAULT = max(
        1, getattr(_hardware_profile, "recommended_chapter_parallel", 1) or 1
    )
if FORCE_TURBO:
    turbo_parallel = max(
        _PARALLEL_SLOTS_DEFAULT,
        (_hardware_profile.cpu_physical or 1) * TURBO_SLOT_MULTIPLIER,
        4,
    )
    _PARALLEL_SLOTS_DEFAULT = turbo_parallel

_CHAPTER_PARALLEL_MAX = max(
    _PARALLEL_SLOTS_DEFAULT,
    int(os.getenv("CHAPTER_PARALLEL_MAX", str(max(4, _PARALLEL_SLOTS_DEFAULT))))
    or _PARALLEL_SLOTS_DEFAULT,
)
if FORCE_TURBO:
    _CHAPTER_PARALLEL_MAX = max(
        _CHAPTER_PARALLEL_MAX,
        (_hardware_profile.cpu_physical or 1) * (TURBO_SLOT_MULTIPLIER + 1),
        6,
    )

_WORKER_CAP = max(
    1,
    min(
        WORKER_MAX,
        max(2, (_hardware_profile.cpu_physical or 1) * TURBO_SLOT_MULTIPLIER),
    ),
)

# Apply profile-specific caps after base calculations to avoid starvation on HF
if _perf_profile == "hf":
    _PARALLEL_SLOTS_DEFAULT = min(_PARALLEL_SLOTS_DEFAULT, 2)
    _CHAPTER_PARALLEL_MAX = min(_CHAPTER_PARALLEL_MAX, 3)
    _WORKER_CAP = min(_WORKER_CAP, max(2, (_hardware_profile.cpu_physical or 1)))
    os.environ.setdefault("EDGE_MAX_CONCURRENCY_CAP", "4")
elif _perf_profile == "cli":
    _PARALLEL_SLOTS_DEFAULT = max(
        _PARALLEL_SLOTS_DEFAULT, min(4, (_hardware_profile.cpu_physical or 1) * 2)
    )
    _CHAPTER_PARALLEL_MAX = max(_CHAPTER_PARALLEL_MAX, min(6, _PARALLEL_SLOTS_DEFAULT + 1))
    _WORKER_CAP = min(max(_WORKER_CAP, (_hardware_profile.cpu_physical or 1) * 2), WORKER_MAX)

# Background task for periodic job cleanup
_cleanup_task: Optional[asyncio.Task] = None
_job_watchdog_task: Optional[asyncio.Task] = None
system_monitor = SystemMonitor(float(os.getenv("SYSTEM_MONITOR_INTERVAL", "2.0")))

if FORCE_TURBO:
    desired_workers = max(2, _hardware_profile.cpu_physical or 1)
    if desired_workers > _JOB_WORKERS:
        logger.warning(
            f"Turbo mode: increasing job workers from {_JOB_WORKERS} to {desired_workers}"
        )
        _JOB_WORKERS = desired_workers


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


def _job_state_counts() -> dict:
    counts = {
        "total": len(jobs),
        "queued": 0,
        "running": 0,
        "finished": 0,
        "failed": 0,
        "cancelled": 0,
    }
    for job in jobs.values():
        state = job.get("state")
        if not state:
            continue
        state_lower = state.lower()
        if state_lower in counts:
            counts[state_lower] += 1
        elif state_lower == "success":
            counts["finished"] += 1
    return counts


def _has_active_jobs() -> bool:
    for job in jobs.values():
        if job.get("state") in {"queued", "running", "cancelling"}:
            return True
    queue = _job_queue
    if queue is not None:
        try:
            return queue.qsize() > 0
        except Exception:
            return False
    return False


def _estimate_recommendations(stats: Optional[dict]) -> dict:
    if not stats:
        return {
            "parallelSlots": _PARALLEL_SLOTS_DEFAULT,
            "jobWorkers": _JOB_WORKERS,
        }
    cpu_info = stats.get("cpu") or {}
    mem_info = stats.get("memory") or {}
    cpu_idle = max(0.0, 100.0 - float(cpu_info.get("percent") or 0.0))
    logical = cpu_info.get("logical") or cpu_info.get("physical") or 1
    available_mem = mem_info.get("available") or 0
    available_gb = available_mem / (1024**3)

    slots = _PARALLEL_SLOTS_DEFAULT
    if cpu_idle > 55 and available_gb > 6:
        slots += 2
    elif cpu_idle > 30 and available_gb > 3:
        slots += 1
    elif cpu_idle < 12 or available_gb < 1.5:
        slots = max(1, slots - 1)
    slots = max(1, min(int(slots), min(_CHAPTER_PARALLEL_MAX, logical)))

    job_workers = _JOB_WORKERS
    if cpu_idle > 65 and available_gb > 8:
        job_workers = min(job_workers + 1, max(1, logical))
    elif cpu_idle < 15 or available_gb < 2:
        job_workers = max(1, job_workers - 1)
    job_workers = max(1, min(job_workers, _WORKER_CAP))

    return {
        "parallelSlots": slots,
        "jobWorkers": job_workers,
    }


def _determine_parallel_slots(requested: int) -> int:
    stats = system_monitor.latest()
    recommendation = _estimate_recommendations(stats)
    target = recommendation["parallelSlots"]
    if FORCE_TURBO:
        return min(_CHAPTER_PARALLEL_MAX, max(requested, target, _CHAPTER_PARALLEL_MAX))
    if requested > target:
        return requested
    return target


def _build_system_stats_payload() -> dict:
    stats = system_monitor.latest() or {}
    job_counts = _job_state_counts()
    telemetry_summary = telemetry.summary()
    queue_depth = 0
    if _job_queue is not None:
        try:
            queue_depth = _job_queue.qsize()
        except Exception:
            queue_depth = 0
    stats_payload = {
        "timestamp": stats.get("timestamp", time.time()),
        "uptimeSeconds": stats.get("uptimeSeconds"),
        "cpu": stats.get("cpu"),
        "memory": stats.get("memory"),
        "swap": stats.get("swap"),
        "disk": stats.get("disk"),
        "network": stats.get("network"),
        "gpus": stats.get("gpus", []),
        "jobs": {
            **job_counts,
            "queueDepth": queue_depth,
            "inFlight": sum(1 for job in jobs.values() if job.get("state") == "running"),
            "workers": {
                "current": len(_job_workers),
                "target": _JOB_WORKERS,
            },
        },
        "recommendations": _estimate_recommendations(stats),
        "telemetry": telemetry_summary,
    }
    return stats_payload


def _handle_stalled_job(job_id: str, job: dict, inactivity_seconds: float) -> bool:
    """
    Handle stalled job. Returns True when conversion should be scheduled inline.
    """
    now = time.time()
    job["_stallHandledAt"] = now
    stage_label = job.get("_lastStage") or job.get("statusHint") or "processo"
    inactivity_label = _format_duration(inactivity_seconds)
    attempts = job.get("_stallRestartCount", 0)
    job["_run_token"] = str(uuid.uuid4())
    message_prefix = f"⚠️ Nenhum progresso há {inactivity_label} (etapa: {stage_label}). "
    if attempts < _STALL_MAX_AUTO_RETRIES:
        job["_stallRestartCount"] = attempts + 1
        job["state"] = "queued"
        job["resumeRequested"] = True
        job["cancelRequested"] = False
        job["statusHint"] = "Reiniciando após detectar travamento"
        _append_event(
            job,
            f"{message_prefix}Tentando novamente automaticamente "
            f"({job['_stallRestartCount']}/{_STALL_MAX_AUTO_RETRIES}).",
        )
        _persist_job(job_id, force=True)
        if not _enqueue_job(job_id):
            return True
        return False

    job["state"] = "interrupted"
    job["resumeRequested"] = False
    job["cancelRequested"] = False
    job["statusHint"] = "Conversão interrompida (sem progresso)"
    job["error"] = (
        "Conversão interrompida automaticamente após falhas repetidas. "
        "Envie novamente ou selecione outro motor de voz."
    )
    job["completedAt"] = now
    _append_event(
        job,
        f"{message_prefix}Interrompemos para evitar travamento permanente. "
        "Tente novamente com configurações diferentes.",
    )
    _persist_job(job_id, force=True)
    _persist_job_log(job_id, job)
    return False


def _detect_stalled_jobs(now: Optional[float] = None) -> list[str]:
    """Identify stalled running jobs and trigger automatic recovery."""
    if now is None:
        now = time.time()
    inline: list[str] = []
    for job_id, job in jobs.items():
        if not job or job.get("state") != "running":
            continue
        if job.get("cancelRequested"):
            continue
        last_activity = _resolve_job_activity_timestamp(job)
        if not last_activity:
            continue
        if job.get("_stallHandledAt") and now - job["_stallHandledAt"] < _STALL_RECHECK_SECONDS:
            continue
        if now - last_activity < _STALL_THRESHOLD_SECONDS:
            continue
        if _handle_stalled_job(job_id, job, now - last_activity):
            inline.append(job_id)
    return inline


async def _job_watchdog():
    """Ensure queued jobs are enqueued and detect stalled queues."""
    while True:
        await asyncio.sleep(5)
        try:
            if _job_queue is None:
                continue
            queued_ids = [job_id for job_id, job in jobs.items() if job.get("state") == "queued"]
            for job_id in queued_ids:
                if job_id in _jobs_in_queue:
                    continue
                _enqueue_job(job_id)

            stats = system_monitor.latest()
            recommendation = _estimate_recommendations(stats)
            queue_depth = _job_queue.qsize()
            target_workers = recommendation["jobWorkers"]
            if FORCE_TURBO:
                target_workers = max(
                    target_workers,
                    (_hardware_profile.cpu_physical or 1) * TURBO_SLOT_MULTIPLIER,
                )
            elif queue_depth > 0:
                target_workers = max(target_workers, min(queue_depth + 1, WORKER_MAX))
            target_workers = max(1, min(target_workers, _WORKER_CAP))
            await _scale_worker_pool(target_workers)
            stalled_inline = _detect_stalled_jobs()
            for stalled_id in stalled_inline:
                asyncio.create_task(process_conversion(stalled_id))
        except Exception as exc:  # pragma: no cover - defensive
            logger.error("Job watchdog encountered an error: %s", exc, exc_info=True)


async def _scale_worker_pool(target: int) -> None:
    global _JOB_WORKERS
    target = max(1, min(target, WORKER_MAX, _WORKER_CAP))
    async with _worker_scale_lock:
        current = len(_job_workers)
        if target == current:
            _JOB_WORKERS = target
            return
        if target > current:
            for _ in range(target - current):
                worker_id = len(_job_workers) + 1
                task = asyncio.create_task(_job_worker(worker_id))
                _job_workers.append(task)
            logger.info("Scaled worker pool up to %s workers", len(_job_workers))
        else:
            for _ in range(current - target):
                task = _job_workers.pop()
                task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await task
            logger.info("Scaled worker pool down to %s workers", len(_job_workers))
        _JOB_WORKERS = target


async def _schedule_restart(delay: float = 0.5) -> None:
    await asyncio.sleep(delay)
    logger.warning("Restarting backend process now")
    os._exit(0)


# Mark jobs as interrupted if they were running/queued (server restart)
# IMPORTANT: On HF Spaces, /tmp is cleared on restart, so source files are lost.
# Jobs that were in progress cannot be resumed without the source file.
# Future enhancement: Save EPUB to R2 for resume capability.
if not _skip_resume_on_startup:
    for job_id, job_data in jobs.items():
        state = job_data.get("state", "")
        job_data.setdefault("cancelRequested", False)
        if state in ("queued", "running"):
            # Check if the source file still exists
            file_path = job_data.get("file_path")
            if file_path and not Path(file_path).exists():
                # Source file was lost (server restart), mark as interrupted
                job_data["state"] = "interrupted"
                job_data["error"] = (
                    "Conversão interrompida (servidor reiniciado e arquivo temporário perdido)"
                )
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
language_detector = LanguageDetector()
MAX_UPLOAD_MB = int(os.getenv("MAX_UPLOAD_MB", "100"))
MAX_UPLOAD_BYTES = MAX_UPLOAD_MB * 1024 * 1024


def _normalise_languages(
    primary_language: Optional[str], languages: Optional[list[str]] = None
) -> list[str]:
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


def _prepare_auto_engine_pool(config: ConversionConfig) -> dict[str, ConversionConfig]:
    pool: dict[str, ConversionConfig] = {}
    for name in ("edge", "coqui", "piper"):
        try:
            candidate = _clone_config_for_engine(config, name)
            pool[name] = candidate
        except Exception:
            continue
    return pool


def _auto_tune_engine_pool(
    pool: dict[str, ConversionConfig],
    *,
    hardware_profile: HardwareProfile,
    network_tier: str,
    total_chars: int,
    force_sequential: bool,
) -> dict[str, dict[str, object]]:
    def _env_int(name: str) -> Optional[int]:
        raw = os.getenv(name, "").strip()
        if not raw:
            return None
        try:
            return int(raw)
        except ValueError:
            return None

    def _env_bool(name: str) -> Optional[bool]:
        raw = os.getenv(name)
        if raw is None:
            return None
        raw = raw.strip().lower()
        if raw == "":
            return None
        return raw in {"1", "true", "yes", "on"}

    summary: dict[str, dict[str, object]] = {}
    tier = (network_tier or "fast").strip().lower()
    total_chars = max(int(total_chars or 0), 0)
    turbo_mode = FORCE_TURBO or os.getenv("MAX_PERFORMANCE", "true").strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    }

    edge_cfg = pool.get("edge")
    if edge_cfg:
        if turbo_mode:
            # Research-based: 8k chars, 90s segments (safe: 3k-8k)
            default_chunk, default_seg, default_wpm = 8000, 90, 185
            if tier == "ultra":
                default_chunk, default_seg, default_wpm = 24000, 95, 200
            elif tier == "fast":
                default_chunk, default_seg, default_wpm = 22000, 90, 190
            elif tier == "medium":
                default_chunk, default_seg, default_wpm = 18000, 85, 180
            elif tier == "slow":
                default_chunk, default_seg, default_wpm = 14000, 75, 170
        else:
            default_chunk, default_seg, default_wpm = 16000, 80, 175
            if tier == "ultra":
                # Research-based: 8k chars, 90s segments (safe: 3k-8k)
                default_chunk, default_seg, default_wpm = 8000, 90, 185
            elif tier == "fast":
                default_chunk, default_seg, default_wpm = 18000, 85, 180
            elif tier == "medium":
                default_chunk, default_seg, default_wpm = 14000, 75, 170
            elif tier == "slow":
                # Turbo mode uses slightly larger chunks
                default_chunk, default_seg, default_wpm = 10000, 65, 160

        if total_chars and total_chars < 8000:
            default_chunk = min(default_chunk, 12000)
            default_seg = min(default_seg, 75)

        chunk_override = _env_int("EDGE_CHUNK_CHARS")
        seg_override = _env_int("EDGE_MAX_SEGMENT_SECONDS")
        parallel_override = _env_bool("EDGE_ENABLE_PARALLEL")

        edge_cfg.edge_chunk_chars = int(chunk_override or default_chunk)
        edge_cfg.edge_max_segment_seconds = int(seg_override or default_seg)
        # Research-based: safe range 3,000-12,000 chars
        edge_cfg.edge_chunk_chars = max(3000, min(edge_cfg.edge_chunk_chars, 12000))
        edge_cfg.edge_max_segment_seconds = max(45, min(edge_cfg.edge_max_segment_seconds, 95))
        if parallel_override is None:
            edge_cfg.edge_enable_parallel = not force_sequential
        else:
            edge_cfg.edge_enable_parallel = parallel_override and not force_sequential

        edge_cfg.extra = dict(edge_cfg.extra or {})
        edge_cfg.extra["edge_auto_wpm"] = int(default_wpm)
        summary["edge"] = {
            "chunk_chars": edge_cfg.edge_chunk_chars,
            "max_segment_seconds": edge_cfg.edge_max_segment_seconds,
            "words_per_minute": int(default_wpm),
            "parallel": edge_cfg.edge_enable_parallel,
        }

    coqui_cfg = pool.get("coqui")
    if coqui_cfg:
        has_gpu = bool(getattr(hardware_profile, "has_gpu", False))
        cpu_physical = int(getattr(hardware_profile, "cpu_physical", 2) or 2)
        ram_total = float(getattr(hardware_profile, "ram_total_gb", 0.0) or 0.0)

        chunk_override = _env_int("COQUI_CHUNK_CHARS")
        workers_override = _env_int("COQUI_MAX_WORKERS")

        if has_gpu:
            if turbo_mode:
                base_chunk = 8000 if ram_total >= 8 else 6500
                base_workers = 3 if ram_total >= 8 else 2
            else:
                base_chunk = 5000 if total_chars < 200000 else 6500
                base_workers = 2 if ram_total >= 8 else 1
        else:
            if cpu_physical >= 8:
                base_chunk = 6000 if turbo_mode else 3500
                base_workers = min(12, cpu_physical * (2 if turbo_mode else 1))
            elif cpu_physical >= 4:
                base_chunk = 5000 if turbo_mode else 3500
                base_workers = min(8, cpu_physical * (2 if turbo_mode else 1))
            else:
                base_chunk = 3500 if turbo_mode else 2500
                base_workers = max(2, min(4, cpu_physical + 1))

        coqui_cfg.coqui_chunk_chars = int(chunk_override or base_chunk)
        coqui_cfg.coqui_max_workers = int(workers_override or base_workers)
        coqui_cfg.coqui_chunk_chars = max(800, min(coqui_cfg.coqui_chunk_chars, 8000))
        coqui_cfg.coqui_max_workers = max(1, min(coqui_cfg.coqui_max_workers, 12))

        summary["coqui"] = {
            "chunk_chars": coqui_cfg.coqui_chunk_chars,
            "max_workers": coqui_cfg.coqui_max_workers,
        }

    return summary


def _pick_auto_engine(
    chapter_chars: int,
    estimated_seconds: float,
    pool: dict[str, ConversionConfig],
    telemetry_speeds: Optional[Dict[str, object]] = None,
    preferred_engine: Optional[str] = None,
) -> tuple[str, list[str]]:
    def _speed_value(entry: object) -> float:
        if isinstance(entry, dict):
            return float(entry.get("avg_chars_per_second") or 0.0)
        try:
            return float(entry or 0.0)
        except (TypeError, ValueError):
            return 0.0

    def _sample_count(entry: object) -> int:
        if isinstance(entry, dict):
            return int(entry.get("samples") or 0)
        return 0

    def append(order: list[str], candidate: str) -> None:
        if candidate in pool and candidate not in order:
            order.append(candidate)

    # Ordem do mais rápido para mais lento: edge > coqui
    order: list[str] = []
    if telemetry_speeds:
        ranked = sorted(
            ((name, _speed_value(telemetry_speeds.get(name, 0.0))) for name in pool.keys()),
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
    if "edge" in order:
        best_name = order[0]
        edge_speed = _speed_value(telemetry_speeds.get("edge", 0.0)) if telemetry_speeds else 0.0
        best_speed = _speed_value(telemetry_speeds.get(best_name, 0.0)) if telemetry_speeds else 0.0
        edge_samples = _sample_count(telemetry_speeds.get("edge", 0)) if telemetry_speeds else 0
        best_samples = _sample_count(telemetry_speeds.get(best_name, 0)) if telemetry_speeds else 0
        prefer_best = (
            best_name != "edge"
            and best_samples >= 3
            and (edge_speed <= 0 or (edge_samples >= 3 and best_speed >= edge_speed * 1.25))
        )
        if not prefer_best:
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


def _next_auto_engine(
    order: list[str], attempted: set[str], pool: dict[str, ConversionConfig]
) -> Optional[str]:
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
    lastActivityAt: Optional[float] = None
    noParallel: Optional[bool] = None


class RestartOptions(BaseModel):
    keep_cache: bool = False
    keep_finished: bool = False


@app.post("/api/convert")
async def convert_ebook(
    background_tasks: BackgroundTasks,
    file: UploadFile | None = File(None),
    upload_id: Optional[str] = Form(None),
    engine: str = Form("edge"),
    voice: Optional[str] = Form(None),
    model: Optional[str] = Form(None),
    chapters: Optional[str] = Form(None),
    sections: Optional[str] = Form(None),
    footnote_mode: Optional[str] = Form("inline"),
    language: Optional[str] = Form(None),
    priority: Optional[str] = Form(None),
    formatting_cues: Optional[str] = Form("on"),
    no_parallel: Optional[str] = Form(None),
    parallel_slots: Optional[str] = Form(None),
    max_performance: Optional[str] = Form(None),
    edge_chunk_chars: Optional[str] = Form(None),
    edge_max_segment_seconds: Optional[str] = Form(None),
    edge_enable_parallel: Optional[str] = Form(None),
    edge_auto_tune: Optional[str] = Form(None),
    coqui_chunk_chars: Optional[str] = Form(None),
    coqui_max_workers: Optional[str] = Form(None),
    coqui_safe_mode: Optional[str] = Form(None),
    piper_max_procs: Optional[str] = Form(None),
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
) -> dict[str, str]:
    speak_cues = _parse_form_bool(formatting_cues, True)
    ui_lang = _normalize_locale(ui_language, "pt")
    disable_parallel = _parse_form_bool(no_parallel, False)
    max_performance_enabled = _parse_form_bool(max_performance, False)
    parallel_slots_override = _parse_form_int(
        parallel_slots,
        min_value=1,
        max_value=_CHAPTER_PARALLEL_MAX,
    )
    edge_chunk_override = _parse_form_int(edge_chunk_chars, min_value=4000, max_value=24000)
    edge_segment_override = _parse_form_int(edge_max_segment_seconds, min_value=30, max_value=120)
    edge_parallel_override = _parse_form_optional_bool(edge_enable_parallel)
    edge_auto_tune_override = _parse_form_optional_bool(edge_auto_tune)
    coqui_chunk_override = _parse_form_int(coqui_chunk_chars, min_value=800, max_value=8000)
    coqui_workers_override = _parse_form_int(coqui_max_workers, min_value=1, max_value=12)
    coqui_safe_override = _parse_form_optional_bool(coqui_safe_mode)
    piper_procs_override = _parse_form_int(piper_max_procs, min_value=1, max_value=12)
    sample_rate_override = _parse_form_int(sample_rate, min_value=8000, max_value=96000)
    channels_override = _parse_form_int(channels, min_value=1, max_value=2)
    clear_cache_flag = _parse_form_bool(clear_cache, False)
    force_reprocess_flag = _parse_form_bool(force_reprocess, False)
    filter_chapters_flag = _parse_form_bool(filter_chapters, False)
    verbose_flag = _parse_form_optional_bool(verbose)
    use_language_detection_flag = _parse_form_optional_bool(use_language_detection)
    prioritize_primary_flag = _parse_form_optional_bool(prioritize_primary_language)
    health_check_interval_override = _parse_form_float(
        health_check_interval_seconds,
        min_value=10.0,
        max_value=300.0,
    )
    health_check_slow_edge_override = _parse_form_float(
        health_check_slow_edge_cps,
        min_value=10.0,
        max_value=500.0,
    )
    health_check_slow_override = _parse_form_float(
        health_check_slow_cps,
        min_value=10.0,
        max_value=300.0,
    )
    health_check_high_cpu_override = _parse_form_float(
        health_check_high_cpu,
        min_value=30.0,
        max_value=100.0,
    )
    health_check_high_mem_override = _parse_form_float(
        health_check_high_mem,
        min_value=30.0,
        max_value=100.0,
    )
    health_check_ok_cpu_override = _parse_form_float(
        health_check_ok_cpu,
        min_value=10.0,
        max_value=100.0,
    )
    health_check_ok_mem_override = _parse_form_float(
        health_check_ok_mem,
        min_value=10.0,
        max_value=100.0,
    )
    health_check_slow_streak_override = _parse_form_int(
        health_check_slow_streak,
        min_value=1,
        max_value=6,
    )
    reuse_upload = None
    job_input_dir = None
    book_title: Optional[str] = None
    book_author: Optional[str] = None
    if upload_id:
        with _pending_lock:
            reuse_upload = _pending_uploads.pop(upload_id, None)
        if not reuse_upload:
            reuse_upload = _load_pending_upload_from_disk(upload_id)
            if not reuse_upload:
                raise HTTPException(status_code=404, detail="Upload não encontrado ou expirado")
        job_id = str(uuid.uuid4())
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
        book_title = reuse_upload.get("book_title")
        book_author = reuse_upload.get("book_author")
        if cover_name:
            cover_source = Path(reuse_upload.get("cover_path") or "")
            if cover_source.exists():
                temp_job = {"bookTitle": book_title, "engine": engine}
                dest_cover = _job_output_dir(job_id, temp_job, ensure=True) / cover_name
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
            if not book_title:
                book_title = reader_for_cover.title
            if not book_author:
                book_author = reader_for_cover.author
            if cover_blob:
                cover_slug = (
                    FileManager.sanitize_filename(
                        reader_for_cover.title or Path(file.filename).stem
                    )
                    or "capa"
                )
                filename = f"{cover_slug}_cover{cover_blob.extension}"
                temp_job = {
                    "bookTitle": book_title or reader_for_cover.title or Path(file.filename).stem,
                    "engine": engine,
                }
                cover_path = _job_output_dir(job_id, temp_job, ensure=True)
                target = cover_path / filename
                target.write_bytes(cover_blob.data)
                cover_name = filename
                cover_url = f"/api/outputs/{job_id}/{filename}"
                cover_mime = cover_blob.media_type
        except Exception:
            pass

    book_title = book_title or (reuse_upload.get("book_title") if reuse_upload else None)
    if not book_title:
        book_title = Path(temp_file.name).stem
    book_author = book_author or (reuse_upload.get("book_author") if reuse_upload else None)
    engine_slug = _engine_slug(engine)
    book_slug = _book_slug(book_title, temp_file.name)
    output_base = output_dir / book_slug
    output_engine_dir = output_base / engine_slug
    output_engine_dir.mkdir(parents=True, exist_ok=True)
    cache_base = CACHE_DIR / book_slug
    cache_engine_dir = cache_base / engine_slug
    cache_engine_dir.mkdir(parents=True, exist_ok=True)

    parallel_slots_value = parallel_slots_override
    if not disable_parallel and max_performance_enabled and parallel_slots_value is None:
        parallel_slots_value = _CHAPTER_PARALLEL_MAX
    if disable_parallel:
        parallel_slots_value = 1
    if parallel_slots_value is None:
        parallel_slots_value = recommend_parallel_slots(engine, _PARALLEL_SLOTS_DEFAULT)

    jobs[job_id] = {
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
        "footnote_mode": footnote_mode,
        "language": language,
        "priority": priority,
        "formattingCues": speak_cues,
        "uiLanguage": ui_lang,
        "outputs": [],
        "bookTitle": book_title,
        "bookAuthor": book_author,
        "outputDir": str(output_engine_dir),
        "cacheDir": str(cache_engine_dir),
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
        "maxPerformance": max_performance_enabled,
        "edgeChunkChars": edge_chunk_override,
        "edgeMaxSegmentSeconds": edge_segment_override,
        "edgeEnableParallel": edge_parallel_override,
        "edgeAutoTune": edge_auto_tune_override,
        "coquiChunkChars": coqui_chunk_override,
        "coquiMaxWorkers": coqui_workers_override,
        "coquiSafeMode": coqui_safe_override,
        "piperMaxProcs": piper_procs_override,
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
        "createdAt": _utcnow_iso(),
        "progressPercent": 0.0,
        "chaptersCompleted": 0,
        "chaptersTotal": 0,
    }
    _update_job_activity(jobs[job_id], stage="queued")
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
    job.pop("_purgeRequested", None)
    job["resumeRequested"] = True
    job["state"] = "queued"
    _append_event(job, "♻️ Retomando conversão a pedido do usuário")
    _persist_job(job_id, force=True)
    if not _enqueue_job(job_id):
        raise HTTPException(status_code=503, detail="Fila de processamento indisponível no momento")
    return {"status": "queued"}


@app.delete("/api/jobs/{job_id}")
async def delete_job(job_id: str) -> dict:
    """Remove a job and its artifacts from disk."""
    job = jobs.get(job_id) or job_manager.load_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    if job_id not in jobs:
        jobs[job_id] = job

    state = job.get("state", "queued")
    if state in {"queued", "running", "cancelling"}:
        job["_purgeRequested"] = True
        job["cancelRequested"] = True
        if state == "queued":
            _finalize_cancel(job_id, job, "🗑️ Conversão removida antes de iniciar")
            return {"status": "deleted"}
        if state != "cancelling":
            job["state"] = "cancelling"
            _append_event(job, "🗑️ Remoção solicitada. Finalizando capítulo atual…")
        _persist_job(job_id, force=True)
        return {"status": "cancelling"}

    _purge_job_data(job_id, job)
    return {"status": "deleted"}


@app.get("/api/outputs/{job_id}/{filename}")
async def download_output(job_id: str, filename: str) -> FileResponse:
    job_data = jobs.get(job_id) or job_manager.load_job(job_id)
    base_dir = _job_output_dir(job_id, job_data)
    file_path = base_dir / filename
    if not file_path.exists():
        # Legacy fallback
        legacy_path = output_dir / job_id / filename
        if legacy_path.exists():
            file_path = legacy_path
        else:
            raise HTTPException(status_code=404, detail="File not found")
    if not file_path.exists():
        raise HTTPException(status_code=404, detail="File not found")
    return FileResponse(path=file_path, media_type=_guess_media_type(filename), filename=filename)


@app.get("/api/streams/{job_id}/chapters/{chapter_index}")
async def stream_manifest(job_id: str, chapter_index: int) -> dict:
    """Return available chunk list for a chapter."""
    chapter_dir = _chapter_chunk_dir(job_id, chapter_index, ensure=False)
    manifest_path = chapter_dir / "manifest.json"
    chunks: list[dict] = []

    if manifest_path.exists():
        try:
            payload = json.loads(manifest_path.read_text(encoding="utf-8"))
            chunks = payload.get("chunks") or []
        except Exception:
            chunks = []
    else:
        # Build manifest from files if no manifest exists
        if chapter_dir.exists():
            for path in sorted(chapter_dir.glob("chunk_*")):
                if path.is_file():
                    name = path.name
                    try:
                        idx_text = name.split("_", 1)[1].split(".")[0]
                        idx_val = int(idx_text)
                    except Exception:
                        idx_val = None
                    chunks.append(
                        {
                            "index": idx_val if idx_val is not None else name,
                            "file": name,
                            "url": f"/api/streams/{job_id}/chapters/{chapter_index}/chunks/{idx_val if idx_val is not None else name}",
                        }
                    )

    base_url = f"/api/streams/{job_id}/chapters/{chapter_index}"

    def _sort_key(item: dict) -> int:
        try:
            return int(item.get("index"))
        except Exception:
            return 0

    return {
        "jobId": job_id,
        "chapterIndex": int(chapter_index),
        "baseUrl": base_url,
        "chunks": sorted(chunks, key=_sort_key),
        "updatedAt": time.time(),
    }


@app.get("/api/streams/{job_id}/chapters/{chapter_index}/chunks/{chunk_id}")
async def stream_chunk(job_id: str, chapter_index: int, chunk_id: str):
    """Serve an individual synthesized chunk for progressive playback."""
    chapter_dir = _chapter_chunk_dir(job_id, chapter_index, ensure=False)
    if not chapter_dir.exists():
        raise HTTPException(status_code=404, detail="Chunk not found")

    candidates = []
    try:
        numeric = int(chunk_id)
        candidates.append(chapter_dir / f"chunk_{numeric:04d}.mp3")
        candidates.append(chapter_dir / f"chunk_{numeric:04d}.wav")
    except Exception:
        pass
    candidates.append(chapter_dir / f"{chunk_id}.mp3")
    candidates.append(chapter_dir / f"{chunk_id}")

    file_path = next((path for path in candidates if path.exists()), None)
    if file_path is None or not file_path.exists():
        raise HTTPException(status_code=404, detail="Chunk not found")

    return FileResponse(path=file_path, media_type=_guess_media_type(file_path.name))


@app.post("/api/cleanup")
async def cleanup_old_files(max_age_hours: int = 48) -> dict:
    """
    Cleanup old files from local storage and R2.

    This endpoint should be called periodically (e.g., via cron job).
    """
    result = {"local_deleted": 0, "r2_deleted": 0, "errors": []}

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


@app.post("/api/system/restart")
async def restart_backend(request: Request) -> dict:
    """
    Request a backend restart. Interrupts all conversions in progress.
    """
    keep_cache = False
    keep_finished = False
    try:
        body = await request.json()
        if body:
            keep_cache = bool(body.get("keep_cache", False))
            keep_finished = bool(body.get("keep_finished", False))
    except Exception:
        pass  # No body or invalid JSON - use defaults
    _write_restart_marker(keep_cache=keep_cache, keep_finished=keep_finished)
    print(f"\n{'='*60}")
    print("🔄 RESTART SOLICITADO")
    print(f"   Manter cache: {keep_cache}")
    print(f"   Manter concluídos: {keep_finished}")
    print(f"{'='*60}")
    logger.warning(
        "Restart requested via API (keep_cache=%s, keep_finished=%s)",
        keep_cache,
        keep_finished,
    )
    print("🧹 Limpando jobs...")
    purged = _purge_all_jobs(
        "restart requested",
        keep_finished=keep_finished,
        purge_cache=not keep_cache,
    )
    print(f"   ✓ {purged} job(s) removido(s)")
    if not keep_finished:
        print("🗑️  Limpando outputs...")
        _clear_all_outputs(preserve_cache=keep_cache)
        print("   ✓ Outputs limpos")
    if not keep_cache:
        print("🗑️  Limpando cache...")
        _clear_all_caches()
        print("   ✓ Cache limpo")
    print(f"{'='*60}")
    print("✅ LIMPEZA CONCLUÍDA - Reiniciando servidor...")
    print(f"{'='*60}\n")
    asyncio.create_task(_schedule_restart())
    return {
        "status": "restarting",
        "purgedJobs": purged,
        "keptCache": keep_cache,
        "keptFinished": keep_finished,
    }


@app.get("/api/system/stats")
async def system_stats() -> dict:
    """Return current hardware usage and scheduler recommendations."""
    return _build_system_stats_payload()


@app.get("/api/health")
async def health_check() -> dict:
    """Health check endpoint for monitoring."""
    from health_monitor import get_health_monitor

    monitor = get_health_monitor()
    latest = monitor.get_latest_snapshot()

    health_data = {
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

    # Add health monitor data if available
    if latest:
        health_data["monitor"] = {
            "heap_status": latest.heap_status,
            "memory_percent": latest.memory_percent,
            "cpu_percent": latest.cpu_percent,
            "gpu_available": latest.gpu_available,
            "thread_count": latest.thread_count,
        }

    return health_data


@app.get("/api/health/monitor")
async def health_monitor_status() -> dict:
    """
    **NOVO**: Health Monitor Status
    Retorna estatísticas detalhadas do monitor de saúde.
    """
    from health_monitor import get_health_monitor

    monitor = get_health_monitor()
    return monitor.get_stats_summary()


@app.get("/api/health/alerts")
async def health_monitor_alerts(max_count: int = 50) -> dict:
    """
    **NOVO**: Health Monitor Alerts
    Retorna alertas recentes do monitor.
    """
    from health_monitor import get_health_monitor

    monitor = get_health_monitor()
    alerts = monitor.get_recent_alerts(max_count=max_count)

    return {
        "alerts": [
            {
                "timestamp": a.timestamp,
                "severity": a.severity,
                "category": a.category,
                "message": a.message,
                "details": a.details,
            }
            for a in alerts
        ],
        "count": len(alerts),
    }


@app.get("/api/health/dashboard")
async def health_monitor_dashboard() -> dict:
    """
    **NOVO**: Health Monitor Dashboard
    Retorna dados completos para dashboard de monitoramento.
    """
    from health_monitor import get_health_monitor

    monitor = get_health_monitor()

    latest = monitor.get_latest_snapshot()
    summary = monitor.get_stats_summary()
    recent_alerts = monitor.get_recent_alerts(max_count=10)

    return {
        "summary": summary,
        "current": {
            "timestamp": latest.timestamp if latest else 0,
            "cpu_percent": latest.cpu_percent if latest else 0,
            "memory_mb": latest.memory_mb if latest else 0,
            "memory_percent": latest.memory_percent if latest else 0,
            "gpu_available": latest.gpu_available if latest else False,
            "gpu_memory_used_mb": latest.gpu_memory_used_mb if latest else 0,
            "gpu_memory_total_mb": latest.gpu_memory_total_mb if latest else 0,
            "gpu_utilization": latest.gpu_utilization if latest else 0,
            "heap_status": latest.heap_status if latest else "unknown",
            "thread_count": latest.thread_count if latest else 0,
        }
        if latest
        else {},
        "recent_alerts": [
            {
                "timestamp": a.timestamp,
                "severity": a.severity,
                "category": a.category,
                "message": a.message,
            }
            for a in recent_alerts
        ],
    }


@app.get("/api/health/recovery")
async def health_recovery_stats() -> dict:
    """
    **NOVO**: Auto-Recovery Statistics
    Retorna estatísticas do sistema de auto-recovery.
    """
    from auto_recovery import get_auto_recovery

    recovery = get_auto_recovery()

    stats = recovery.get_stats()
    recent_actions = recovery.get_recent_actions(max_count=20)

    return {
        "stats": stats,
        "recent_actions": [
            {
                "timestamp": datetime.fromtimestamp(a.timestamp).isoformat(),
                "problem": a.problem,
                "action": a.action,
                "success": a.success,
                "details": a.details,
            }
            for a in recent_actions
        ],
    }


@app.get("/api/jobs/resumable")
async def get_resumable_jobs() -> dict:
    """Get list of jobs that can be resumed."""
    resumable = _collect_resumable_job_entries()
    return {"resumable_jobs": resumable, "count": len(resumable)}


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
        },
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
            cache_manager = get_cache_manager()
            chapters_list = list(reader.get_chapters())
            if chapters_list:
                chapters_data = {
                    "title": book_title,
                    "author": book_author,
                    "chapters": [
                        {
                            "title": getattr(ch, "name", f"Chapter {i}"),
                            "text": getattr(ch, "text", ""),
                        }
                        for i, ch in enumerate(chapters_list, 1)
                    ],
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
        _write_pending_upload_metadata(upload_dir, _pending_uploads[upload_id])

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
    job_data = jobs.get(job_id)
    if not job_data:
        logger.warning(f"Cannot persist job {job_id}: not found in memory")
        return

    if not force:
        _schedule_job_broadcast(job_id, job_data)
        return  # Skip for non-critical updates

    success = job_manager.save_job(job_id, job_data)
    if not success:
        logger.error(f"Failed to persist job {job_id} to disk")
    else:
        # **OPTIMIZATION #1**: Update index when job is persisted
        saved_at = _determine_saved_at(job_data)
        book_title = job_data.get("bookTitle") or "Unknown"
        state = (job_data.get("state") or "").lower()
        if state == "cancelled":
            _recent_jobs_index.pop(job_id, None)
        else:
            _recent_jobs_index[job_id] = (saved_at, book_title)
    _schedule_job_broadcast(job_id, job_data)


def _cleanup_job_output(job_id: str) -> None:
    """Remove the job output directory."""
    job_dir = _job_output_dir(job_id)
    if job_dir.exists():
        shutil.rmtree(job_dir, ignore_errors=True)


def _remove_job_from_queue(job_id: str) -> None:
    """Remove a job from the worker queue if it is still queued."""
    queue = _job_queue
    if queue is None:
        return
    pending: list[str] = []
    while True:
        try:
            queued_id = queue.get_nowait()
            queue.task_done()
        except asyncio.QueueEmpty:
            break
        if queued_id != job_id:
            pending.append(queued_id)
    for queued_id in pending:
        queue.put_nowait(queued_id)
    _jobs_in_queue.clear()
    _jobs_in_queue.update(pending)


def _cleanup_job_inputs(job: dict) -> None:
    """Remove uploaded source files for a job."""
    source_path = Path(job.get("file_path") or "")
    with contextlib.suppress(OSError):
        source_path.unlink(missing_ok=True)
    upload_dir_path = Path(job.get("uploadDir") or "")
    if upload_dir_path.exists():
        shutil.rmtree(upload_dir_path, ignore_errors=True)


def _delete_job_storage_assets(job_id: str, job: dict) -> None:
    """Best-effort deletion of stored outputs (R2) for a job."""
    if not storage.is_enabled():
        return
    outputs = job.get("outputs") or []
    for asset in outputs:
        key = asset.get("r2_key") or (
            f"{job_id}/{asset.get('name')}" if asset.get("name") else None
        )
        if key:
            storage.delete_file(key)
    cover_entry = job.get("cover") or {}
    cover_key = cover_entry.get("r2_key") or (
        f"{job_id}/{cover_entry.get('name')}" if cover_entry.get("name") else None
    )
    if cover_key:
        storage.delete_file(cover_key)


def _purge_job_data(job_id: str, job: Optional[dict] = None, *, purge_cache: bool = True) -> None:
    """Remove all persisted data and artifacts for a job."""
    _remove_job_from_queue(job_id)
    if job:
        if purge_cache:
            _clear_job_cache(job)
        _cleanup_job_inputs(job)
        _delete_job_storage_assets(job_id, job)
    _cleanup_job_output(job_id)
    job_manager.delete_job(job_id)
    jobs.pop(job_id, None)
    _recent_jobs_index.pop(job_id, None)
    if job_id in _sse_clients:
        _sse_clients.pop(job_id, None)


def _purge_all_jobs(reason: str, *, keep_finished: bool = False, purge_cache: bool = True) -> int:
    """Remove all known jobs and their artifacts."""
    job_ids = set(jobs.keys()) | set(job_manager.list_all_jobs())
    purged_count = 0
    for job_id in list(job_ids):
        job_data = jobs.get(job_id) or job_manager.load_job(job_id)
        state = (job_data.get("state") or "").lower() if job_data else ""
        if keep_finished and state in {"finished", "success"}:
            continue
        if job_data:
            job_data["_purgeRequested"] = True
            job_data["cancelRequested"] = True
            job_data["resumeRequested"] = False
        _purge_job_data(job_id, job_data, purge_cache=purge_cache)
        purged_count += 1
    logger.warning("Purged %s job(s): %s", purged_count, reason)
    try:
        jobs.clear()
        _recent_jobs_index.clear()
        # Clear in-memory cache of JobManager
        if hasattr(job_manager, "_memory_cache"):
            job_manager._memory_cache.clear()  # type: ignore[attr-defined]
    except Exception:
        pass
    return purged_count


def _clear_job_cache(job: dict) -> None:
    """Clear cached chapters/audio for this job."""
    try:
        cache_manager = get_cache_manager()
        source_path = Path(job.get("file_path", "")) if job.get("file_path") else None
        book_title = job.get("bookTitle")
        if source_path and source_path.exists():
            cache_manager.clear_cache(source_path, title=book_title)
        elif book_title:
            cache_manager.clear_cache(title=book_title)
    except Exception:
        pass


def _clear_all_caches() -> None:
    """Clear global caches (chapters + covers) on restart purge."""
    try:
        get_cache_manager().clear_cache()
    except Exception:
        pass


def _clear_all_outputs(*, preserve_cache: bool) -> None:
    """Clear all outputs and persistent job artifacts for a clean restart."""

    def _safe_remove(path: Path) -> None:
        try:
            if path.is_dir():
                shutil.rmtree(path, ignore_errors=True)
            else:
                path.unlink(missing_ok=True)
        except Exception:
            pass

    def _should_preserve(entry: Path) -> bool:
        if not preserve_cache:
            return False
        try:
            return entry.resolve() == cover_cache_dir.resolve()
        except Exception:
            return False

    def _is_restart_marker(entry: Path) -> bool:
        try:
            return entry.resolve() == _restart_marker_path.resolve()
        except Exception:
            return False

    if output_dir.exists():
        for entry in output_dir.iterdir():
            if _should_preserve(entry) or _is_restart_marker(entry):
                continue
            _safe_remove(entry)

    for entry in (uploads_dir, job_inputs_dir, jobs_state_dir):
        if entry.exists():
            _safe_remove(entry)
        entry.mkdir(parents=True, exist_ok=True)


def _clear_restart_staging_dirs() -> None:
    """Clear transient uploads/inputs without touching completed outputs."""
    for entry in (uploads_dir, job_inputs_dir):
        if entry.exists():
            shutil.rmtree(entry, ignore_errors=True)
        entry.mkdir(parents=True, exist_ok=True)
    try:
        if cover_cache_dir.exists():
            shutil.rmtree(cover_cache_dir, ignore_errors=True)
        cover_cache_dir.mkdir(exist_ok=True, parents=True)
        cover_cache_index.clear()
        _save_cover_cache(cover_cache_index)
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
    if job.get("_purgeRequested"):
        _purge_job_data(job_id, job)
        return
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
    job_dir = _job_output_dir(job_id, job, ensure=True)
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
    if not job.get("startedAt"):
        job["startedAt"] = _utcnow_iso()
    run_token = str(uuid.uuid4())
    job["_run_token"] = run_token
    _update_job_activity(job, stage="starting")

    def _should_abort_current_run(note: Optional[str] = None) -> bool:
        if job.get("cancelRequested"):
            _finalize_cancel(job_id, job, note or "🛑 Conversão cancelada antes de iniciar")
            return True
        if job.get("_run_token") != run_token:
            _append_event(job, "⏹️ Execução atual substituída por uma nova tentativa.")
            return True
        return False

    try:
        if _should_abort_current_run("🛑 Conversão cancelada antes de iniciar"):
            return

        job["state"] = "running"
        job["statusHint"] = "Preparando conversão..."

        # Reset adaptive Edge TTS settings for new conversion
        reset_adaptive_settings()

        _append_event(job, "📚 METADADOS DO EBOOK")
        _append_event(job, "=" * 64)
        _persist_job(job_id, force=True)  # Persist state change
        _schedule_job_broadcast(job_id, job)  # Broadcast running state to UI immediately
        _update_job_activity(job, stage="metadata")

        file_path = Path(job["file_path"])
        max_performance = bool(job.get("maxPerformance"))
        filter_chapters_flag = bool(job.get("filterChapters"))
        clear_cache_flag = bool(job.get("clearCache"))
        force_reprocess_flag = bool(job.get("forceReprocess"))
        verbose_flag = job.get("verbose")
        use_language_detection_flag = job.get("useLanguageDetection")
        prioritize_primary_flag = job.get("prioritizePrimaryLanguage")
        edge_chunk_override = job.get("edgeChunkChars")
        edge_segment_override = job.get("edgeMaxSegmentSeconds")
        edge_parallel_override = job.get("edgeEnableParallel")
        edge_auto_tune_override = job.get("edgeAutoTune")
        coqui_chunk_override = job.get("coquiChunkChars")
        coqui_workers_override = job.get("coquiMaxWorkers")
        coqui_safe_override = job.get("coquiSafeMode")
        piper_procs_override = job.get("piperMaxProcs")

        if max_performance:
            if edge_chunk_override is None:
                edge_chunk_override = 24000
            if edge_segment_override is None:
                edge_segment_override = 95
            if edge_parallel_override is None:
                edge_parallel_override = True
            if coqui_chunk_override is None:
                coqui_chunk_override = 8000
            if coqui_workers_override is None:
                cpu_physical = int(getattr(_hardware_profile, "cpu_physical", 2) or 2)
                has_gpu = bool(getattr(_hardware_profile, "has_gpu", False))
                ram_total = float(getattr(_hardware_profile, "ram_total_gb", 0.0) or 0.0)
                if has_gpu:
                    coqui_workers_override = 3 if ram_total >= 8 else 2
                else:
                    coqui_workers_override = min(12, max(2, cpu_physical * 2))
            if piper_procs_override is None:
                cpu_physical = int(getattr(_hardware_profile, "cpu_physical", 2) or 2)
                piper_procs_override = min(6, max(1, cpu_physical))

        if clear_cache_flag:
            _append_event(job, "🗑️ Limpando cache do livro antes de iniciar…")
            _clear_job_cache(job)
        _append_event(job, "📖 Analisando estrutura do ebook...")

        # **ASYNC OPTIMIZATION**: Run blocking I/O in thread pool
        loop = asyncio.get_event_loop()
        reader = await loop.run_in_executor(None, EbookReader, str(file_path))

        _update_job_activity(job, stage="structure_analysis")
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

        # Prepare chapters first to analyze language
        _append_event(job, "📑 Extraindo capítulos do livro...")
        _update_job_activity(job, stage="chapter_extraction")
        selector_parts = [job.get("chapters"), job.get("sections")]
        selector_text = " ".join(part for part in selector_parts if part)
        temp_output_base = output_dir / _book_slug(job.get("bookTitle"), job.get("file_path"))
        temp_config = ConversionConfig(
            engine="edge",  # Temporary, just for chapter parsing
            output_dir=str(temp_output_base),
            preserve_all_chapters=not filter_chapters_flag,
        )
        chapters = _prepare_chapters(reader, temp_config, selector_text)
        _append_event(job, f"✅ {len(chapters)} capítulos encontrados")
        job["chaptersTotal"] = len(chapters)
        _schedule_job_broadcast(job_id, job)  # Broadcast chapter count to UI
        _update_job_activity(job, stage="chapters_ready")

        # Detect language from book content
        _append_event(job, "")
        _append_event(job, "🌐 DETECÇÃO DE IDIOMA")
        _append_event(job, "-" * 64)

        # Use user-specified language if provided, otherwise detect
        if job.get("language") and job.get("language").lower() not in ("auto", ""):
            detected_lang = job.get("language")
            _append_event(job, f"🌐 Idioma especificado pelo usuário: {detected_lang}")
        else:
            _append_event(job, "🔍 Analisando conteúdo para detectar idioma...")
            # Sample text from multiple chapters for better detection
            sample_texts = []
            max_samples = min(10, len(chapters))  # Use up to 10 chapters
            step = max(1, len(chapters) // max_samples)

            for i in range(0, len(chapters), step):
                if len(sample_texts) >= max_samples:
                    break
                chapter = chapters[i]
                text = getattr(chapter, "text", "") or ""
                if text and len(text) > 100:
                    # Take first 500 chars from each sampled chapter
                    sample_texts.append(text[:500])

            if sample_texts:
                try:
                    profile = language_detector.detect_profile(sample_texts, max_chars=8000)
                    detected_lang = profile.primary or "pt-BR"
                    if profile.predictions and len(profile.predictions) > 0:
                        confidence = profile.predictions[0].probability
                        _append_event(
                            job,
                            f"🌐 Idioma detectado: {detected_lang} (confiança: {confidence:.1%})",
                        )
                    else:
                        _append_event(job, f"🌐 Idioma detectado: {detected_lang}")
                except Exception as e:
                    detected_lang = "pt-BR"
                    _append_event(job, f"⚠️ Erro na detecção de idioma: {e}")
                    _append_event(job, f"🌐 Usando idioma padrão: {detected_lang}")
            else:
                detected_lang = "pt-BR"
                _append_event(
                    job, f"🌐 Sem texto suficiente para detecção, usando: {detected_lang}"
                )

        job["detectedLanguage"] = detected_lang
        _persist_job(job_id, force=True)  # Persist metadata
        _update_job_activity(job, stage="language_detected")

        # Create log callback to capture verbose TTS engine output
        def tts_log_callback(message: str) -> None:
            """Capture verbose TTS output and add to raw log + statusHint."""
            raw_log = job.setdefault("_raw_log", [])
            raw_log.append(message)
            # Show model loading/downloading status in UI
            if any(
                kw in message.lower()
                for kw in [
                    "carregando",
                    "baixando",
                    "modelo",
                    "loading",
                    "download",
                    "pronto",
                    "ready",
                ]
            ):
                job["statusHint"] = message

        # Resolve per-book/per-engine roots
        book_slug = _book_slug(job.get("bookTitle"), job.get("file_path"))
        engine_slug = _engine_slug(job.get("engine"))
        output_root = Path(job.get("outputDir") or (output_dir / book_slug / engine_slug))
        cache_root = Path(job.get("cacheDir") or (CACHE_DIR / book_slug / engine_slug))

        # Create TTS engine using factory with optimized compression
        verbose_enabled = True if verbose_flag is None else bool(verbose_flag)
        model_path = Path(job.get("model")) if job.get("model") else None
        config = ConversionConfig(
            engine=job.get("engine", "edge"),
            job_id=job_id,
            voice=job.get("voice"),
            model_path=model_path,
            primary_language=detected_lang,
            output_dir=str(output_root),
            cache_dir=str(cache_root),
            preserve_all_chapters=not filter_chapters_flag,
            # Optimized compression for web delivery (reduce file size & bandwidth)
            bitrate=job.get("bitrate") or "8k",  # 8 kbps - good quality for voice, ~3.6 MB/hour
            sample_rate=job.get("sampleRate") or 16_000,  # 16 kHz - sufficient for speech
            channels=job.get("channels") or 1,  # Mono - audiobooks don't need stereo
            force_reprocess=bool(job.get("forceReprocess")),
            clear_cache=clear_cache_flag,
            languages=[detected_lang] if detected_lang and detected_lang.lower() != "auto" else [],
            priority_selectors=[
                token.strip()
                for token in re.split(r"[\s,;]+", job.get("priority") or "")
                if token.strip()
            ],
            speak_formatting_cues=job.get("formattingCues", True),
            formatting_locale=_normalize_locale(job.get("uiLanguage"), "pt"),
            use_language_detection=True
            if use_language_detection_flag is None
            else bool(use_language_detection_flag),
            prioritize_primary_language=True
            if prioritize_primary_flag is None
            else bool(prioritize_primary_flag),
            coqui_chunk_chars=coqui_chunk_override,
            coqui_max_workers=coqui_workers_override,
            coqui_safe_mode=coqui_safe_override,
            piper_max_procs=piper_procs_override,
            verbose=verbose_enabled,  # Enable verbose logging for terminal-like output
            log_callback=tts_log_callback,  # Capture all verbose logs
        )
        if (config.engine or "").lower() == "edge":
            # **PERFORMANCE OPTIMIZATIONS**: Use auto-tuned Edge profile from hardware/network detector
            def _env_int(name: str, fallback: int) -> int:
                raw = os.getenv(name, "").strip()
                try:
                    return int(raw) if raw else fallback
                except ValueError:
                    return fallback

            config.edge_aggressive_mode = False  # Aggressive mode conflicts with tuned parallelism
            if edge_parallel_override is not None:
                config.edge_enable_parallel = bool(edge_parallel_override)
            else:
                config.edge_enable_parallel = os.getenv("EDGE_ENABLE_PARALLEL", "true").lower() in (
                    "true",
                    "1",
                    "yes",
                )
            if edge_chunk_override is not None:
                config.edge_chunk_chars = int(edge_chunk_override)
            else:
                # Research-based default: 8k chars
                config.edge_chunk_chars = _env_int(
                    "EDGE_CHUNK_CHARS", config.edge_chunk_chars or 8000
                )
            if edge_segment_override is not None:
                config.edge_max_segment_seconds = int(edge_segment_override)
            else:
                config.edge_max_segment_seconds = _env_int(
                    "EDGE_MAX_SEGMENT_SECONDS", config.edge_max_segment_seconds or 75
                )
        force_sequential = bool(job.get("noParallel"))
        if force_sequential:
            config.edge_enable_parallel = False

        def _apply_engine_overrides(target: ConversionConfig) -> None:
            if edge_chunk_override is not None:
                target.edge_chunk_chars = int(edge_chunk_override)
            if edge_segment_override is not None:
                target.edge_max_segment_seconds = int(edge_segment_override)
            if edge_parallel_override is not None:
                target.edge_enable_parallel = bool(edge_parallel_override)
            if coqui_chunk_override is not None:
                target.coqui_chunk_chars = int(coqui_chunk_override)
            if coqui_workers_override is not None:
                target.coqui_max_workers = int(coqui_workers_override)
            if coqui_safe_override is not None:
                target.coqui_safe_mode = bool(coqui_safe_override)
            if piper_procs_override is not None:
                target.piper_max_procs = int(piper_procs_override)

        _apply_engine_overrides(config)
        if force_sequential:
            config.edge_enable_parallel = False

        # Store original before deduplication for potential restoration
        original_chapters = chapters.copy()

        chapters, duplicates_removed = deduplicate_chapters_by_content(chapters)
        if duplicates_removed:
            _append_event(job, f"🧹 Capítulo duplicado detectado: {duplicates_removed} removido(s)")

        # Validate chapter count against TOC
        expected_count = getattr(reader, "_toc_expected_chapters", 0)
        if expected_count > 0 and len(chapters) != expected_count and duplicates_removed > 0:
            if len(chapters) + duplicates_removed == expected_count:
                _append_event(
                    job,
                    f"⚠️  VALIDAÇÃO: TOC indica {expected_count} capítulos, mas foram detectados {len(chapters)}",
                )
                _append_event(
                    job,
                    f"🔄 Auto-correção: restaurando {duplicates_removed} capítulo(s) removido(s)",
                )
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
        chapter_char_totals: dict[int, int] = {}
        total_chars = 0
        for idx, chapter in enumerate(chapters, 1):
            chapter_text = getattr(chapter, "speech_text", None) or chapter.text or ""
            clean_text = TextFormattingProcessor.strip_inline_markdown(chapter_text)
            chapter_chars = len(clean_text)
            chapter_char_totals[idx] = chapter_chars
            total_chars += chapter_chars
        job["totalChars"] = total_chars
        job["processedChars"] = 0
        job["_chapterCharTotals"] = chapter_char_totals
        job["_chapterCharProcessed"] = {idx: 0 for idx in chapter_char_totals}
        job["_chapterLastProgressUpdate"] = {idx: 0.0 for idx in chapter_char_totals}
        job["_lastProgressBroadcast"] = 0.0

        def _recalculate_progress() -> float:
            total_for_job = job.get("totalChars") or 0
            processed_for_job = job.get("processedChars") or 0
            if total_for_job > 0:
                progress = (processed_for_job / total_for_job) * 100
            else:
                completed = max(0, min(len(chapters), job.get("chaptersCompleted", 0)))
                progress = (completed / max(len(chapters), 1)) * 100
            progress = max(job.get("progressPercent") or 0.0, min(100.0, max(0.0, progress)))
            job["progressPercent"] = progress
            return progress

        def _broadcast_progress(force: bool = False) -> None:
            now = time.time()
            last_emit = job.get("_lastProgressBroadcast") or 0.0
            if force or (now - last_emit) >= 0.5:
                job["_lastProgressBroadcast"] = now
                _schedule_job_broadcast(job.get("jobId"), job)

        def _update_job_progress(force_broadcast: bool = False) -> None:
            _recalculate_progress()
            if force_broadcast:
                _broadcast_progress(force=True)

        def _advance_chapter_progress(
            chapter_index: int,
            segment_text: str,
            total_text_chars: Optional[int] = None,
        ) -> None:
            if not segment_text:
                return
            chapter_totals = job.get("_chapterCharTotals") or {}
            chapter_processed = job.get("_chapterCharProcessed") or {}
            chapter_total = chapter_totals.get(chapter_index)
            if total_text_chars and total_text_chars > 0:
                if chapter_total is None or total_text_chars > chapter_total:
                    delta_total = total_text_chars - (chapter_total or 0)
                    chapter_totals[chapter_index] = total_text_chars
                    job["_chapterCharTotals"] = chapter_totals
                    job["totalChars"] = max(0, (job.get("totalChars") or 0) + delta_total)
                    chapter_total = total_text_chars
            current_processed = int(chapter_processed.get(chapter_index, 0) or 0)
            delta = len(segment_text)
            if chapter_total and chapter_total > 0:
                remaining = max(chapter_total - current_processed, 0)
                delta = min(delta, remaining)
            if delta <= 0:
                return
            chapter_processed[chapter_index] = current_processed + delta
            job["_chapterCharProcessed"] = chapter_processed
            job["processedChars"] = min(
                job.get("totalChars") or 0, (job.get("processedChars") or 0) + delta
            )
            chapter_progress_ts = job.get("_chapterLastProgressUpdate") or {}
            chapter_progress_ts[chapter_index] = time.time()
            job["_chapterLastProgressUpdate"] = chapter_progress_ts
            _update_job_activity(job)
            _update_job_progress()
            _broadcast_progress()

        def _complete_chapter_progress(chapter_index: int, *, broadcast: bool = True) -> None:
            chapter_totals = job.get("_chapterCharTotals") or {}
            chapter_processed = job.get("_chapterCharProcessed") or {}
            chapter_total = int(chapter_totals.get(chapter_index, 0) or 0)
            if chapter_total > 0:
                current_processed = int(chapter_processed.get(chapter_index, 0) or 0)
                if chapter_total > current_processed:
                    delta = chapter_total - current_processed
                    chapter_processed[chapter_index] = chapter_total
                    job["_chapterCharProcessed"] = chapter_processed
                    job["processedChars"] = min(
                        job.get("totalChars") or 0, (job.get("processedChars") or 0) + delta
                    )
            chapter_progress_ts = job.get("_chapterLastProgressUpdate") or {}
            chapter_progress_ts[chapter_index] = time.time()
            job["_chapterLastProgressUpdate"] = chapter_progress_ts
            _update_job_progress(force_broadcast=broadcast)

        def _update_estimated_chapter_progress(chapter_index: int, ratio: float) -> None:
            if ratio <= 0:
                return
            chapter_totals = job.get("_chapterCharTotals") or {}
            chapter_processed = job.get("_chapterCharProcessed") or {}
            chapter_total = int(chapter_totals.get(chapter_index, 0) or 0)
            if chapter_total <= 0:
                return
            clamped_ratio = min(max(ratio, 0.0), 0.97)
            target = int(chapter_total * clamped_ratio)
            current_processed = int(chapter_processed.get(chapter_index, 0) or 0)
            if target <= current_processed:
                return
            delta = target - current_processed
            chapter_processed[chapter_index] = target
            job["_chapterCharProcessed"] = chapter_processed
            job["processedChars"] = min(
                job.get("totalChars") or 0, (job.get("processedChars") or 0) + delta
            )
            chapter_progress_ts = job.get("_chapterLastProgressUpdate") or {}
            chapter_progress_ts[chapter_index] = time.time()
            job["_chapterLastProgressUpdate"] = chapter_progress_ts
            _update_job_activity(job)
            _update_job_progress()
            _broadcast_progress()

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
        active_config: Optional[ConversionConfig] = None
        auto_mode = (config.engine or "").lower() == "auto"

        auto_engine_pool: dict[str, ConversionConfig] = {}
        telemetry_speeds: Dict[str, object] = {}
        preferred_auto_engine: Optional[str] = None
        engine_seeds: dict[str, object] = {}
        unavailable_engines: set[str] = set()
        auto_tuning_summary: dict[str, dict[str, object]] = {}
        auto_edge_profile: Optional[dict[str, object]] = None
        edge_network_tier = (
            (getattr(_hardware_profile, "network_speed_estimate", "fast") or "fast").strip().lower()
        )

        if not auto_mode:
            _append_event(job, "")
            _append_event(job, f"🔧 Inicializando engine de TTS ({config.engine})...")
            while engine_index < len(engine_chain):
                candidate = engine_chain[engine_index]
                engine_name = (candidate.engine or "").lower()
                _set_engine_status(job, engine_name, "loading", "Carregando modelo...")
                try:
                    engine_obj = tts_factory.create_engine(candidate)
                    active_config = candidate
                    if engine_name:
                        engine_seeds[engine_name] = engine_obj
                    _set_engine_status(job, engine_name, "ready", "Pronto")
                    _append_event(job, f"✅ Engine {candidate.engine} pronto")
                    break
                except ImportError as exc:
                    _set_engine_status(job, engine_name, "error", str(exc))
                    _append_event(job, f"⚠️ Engine '{candidate.engine}' indisponível: {exc}")
                except Exception as exc:
                    _set_engine_status(job, engine_name, "error", str(exc))
                    _append_event(job, f"⚠️ Falha ao iniciar engine '{candidate.engine}': {exc}")
                engine_index += 1

            if not engine_seeds or active_config is None:
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
            auto_tuning_summary = _auto_tune_engine_pool(
                auto_engine_pool,
                hardware_profile=_hardware_profile,
                network_tier=edge_network_tier,
                total_chars=total_chars,
                force_sequential=force_sequential,
            )
            for pool_config in auto_engine_pool.values():
                _apply_engine_overrides(pool_config)
                if force_sequential:
                    pool_config.edge_enable_parallel = False
            auto_edge_profile = auto_tuning_summary.get("edge")
            if auto_edge_profile and (
                edge_chunk_override is not None
                or edge_segment_override is not None
                or edge_parallel_override is not None
            ):
                auto_edge_profile = {
                    **auto_edge_profile,
                    "chunk_chars": edge_chunk_override or auto_edge_profile.get("chunk_chars"),
                    "max_segment_seconds": edge_segment_override
                    or auto_edge_profile.get("max_segment_seconds"),
                    "parallel": bool(edge_parallel_override)
                    if edge_parallel_override is not None
                    else auto_edge_profile.get("parallel"),
                }
                auto_tuning_summary["edge"] = auto_edge_profile
            if auto_edge_profile:
                _append_event(
                    job,
                    "⚡ Auto Edge: "
                    f"{auto_edge_profile.get('chunk_chars')} chars, "
                    f"{auto_edge_profile.get('max_segment_seconds')}s, "
                    f"{auto_edge_profile.get('words_per_minute')} wpm",
                )
            coqui_profile = auto_tuning_summary.get("coqui")
            if coqui_profile:
                _append_event(
                    job,
                    "⚡ Auto Coqui: "
                    f"{coqui_profile.get('chunk_chars')} chars, "
                    f"{coqui_profile.get('max_workers')} workers",
                )

        _append_event(job, "")
        _append_event(job, f"🎙️ Engine: {active_config.engine}")
        _append_event(job, f"🗣️ Voz: {active_config.voice or 'padrão'}")
        _update_job_activity(job, stage="tts_ready")
        has_edge_engine = (active_config.engine or "").lower() == "edge"
        if not has_edge_engine and auto_engine_pool:
            has_edge_engine = any(
                (pool_config.engine or "").lower() == "edge"
                for pool_config in auto_engine_pool.values()
            )
        edge_auto_tune_flag = (
            EDGE_AUTO_TUNE if edge_auto_tune_override is None else bool(edge_auto_tune_override)
        )
        edge_auto_tune = edge_auto_tune_flag and has_edge_engine
        parallel_slots_cap: Optional[int] = 1 if force_sequential else None
        if edge_auto_tune and not force_sequential:
            parallel_slots_cap = EDGE_AUTO_PARALLEL_CAPS.get(
                edge_network_tier, EDGE_SAFE_CHAPTER_PARALLEL
            )
        requested_slots = (
            1
            if force_sequential
            else max(1, int(job.get("parallelSlots") or _PARALLEL_SLOTS_DEFAULT))
        )
        parallel_slots = 1 if force_sequential else _determine_parallel_slots(requested_slots)
        if parallel_slots_cap:
            parallel_slots = min(parallel_slots, parallel_slots_cap)
            requested_slots = min(requested_slots, parallel_slots_cap)
        edge_cap = 0
        if has_edge_engine:
            try:
                edge_cap = int(os.getenv("EDGE_MAX_CONCURRENCY", "") or "0")
            except ValueError:
                edge_cap = 0
            if edge_cap > 0:
                parallel_slots = max(1, min(parallel_slots, edge_cap))
        active_jobs = sum(1 for job_data in jobs.values() if job_data.get("state") == "running")
        if not force_sequential and active_jobs > 1:
            balanced_slots = max(1, parallel_slots // active_jobs)
            if balanced_slots < parallel_slots:
                _append_event(
                    job,
                    f"⚖️ {active_jobs} conversões ativas → ajustando paralelismo {parallel_slots}→{balanced_slots}",
                )
                parallel_slots = balanced_slots
        job["parallelSlots"] = parallel_slots
        if force_sequential:
            _append_event(job, "🔒 Paralelismo desativado (1 capítulo por vez)")
        elif edge_auto_tune and parallel_slots_cap:
            _append_event(
                job,
                f"🌐 Edge auto-ajuste: limite {parallel_slots_cap} capítulo(s) em paralelo ({edge_network_tier})",
            )
        elif parallel_slots > 1:
            _append_event(
                job, f"🚀 Paralelo automático: até {parallel_slots} capítulos simultâneos"
            )
        else:
            _append_event(job, "🔄 Modo sequencial: 1 capítulo por vez")

        def _engine_pool_snapshot() -> ResourceSnapshot:
            stats = system_monitor.latest() or {}
            cpu_info = stats.get("cpu") or {}
            mem_info = stats.get("memory") or {}
            cpu_percent = float(cpu_info.get("percent") or 0.0)
            cpu_idle = max(0.0, 100.0 - cpu_percent)
            mem_available = float(mem_info.get("available") or 0.0)
            ram_gb = mem_available / (1024**3) if mem_available else 0.0
            active_jobs = sum(1 for job_data in jobs.values() if job_data.get("state") == "running")
            return ResourceSnapshot(
                cpu_percent=cpu_percent,
                cpu_idle=cpu_idle,
                ram_gb=ram_gb,
                active_jobs=max(1, active_jobs),
            )

        engine_pool = JobEnginePool(
            create_engine=tts_factory.create_engine,
            parallel_slots=parallel_slots,
            edge_cap=edge_cap,
            hardware_profile=_hardware_profile,
            stats_provider=_engine_pool_snapshot,
        )
        registered_engines: set[str] = set()
        if auto_mode:
            for name, pool_config in auto_engine_pool.items():
                engine_pool.register_engine(name, pool_config, engine_seeds.get(name))
                registered_engines.add(name)
        else:
            for candidate in engine_chain:
                name = (candidate.engine or "").lower()
                if not name or name in registered_engines:
                    continue
                engine_pool.register_engine(name, candidate, engine_seeds.get(name))
                registered_engines.add(name)

        job_output_dir = _job_output_dir(job_id, job, ensure=True)
        resume_mode = (
            bool(job.get("resumeRequested"))
            and job_output_dir.exists()
            and not force_reprocess_flag
        )

        # Preserve uploaded source file before cleaning the output directory.
        source_path_str = job.get("file_path")
        if source_path_str:
            source_path = Path(source_path_str)
            try:
                if source_path.exists() and source_path.is_relative_to(job_output_dir):
                    safe_source = job_output_dir / f"{job_id}_{source_path.name}"
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
                    temp_cover = job_output_dir.parent / f"{job_id}_{cover_name}.tmp"
                    try:
                        shutil.move(str(cover_path), str(temp_cover))
                        cover_restore = (temp_cover, cover_path)
                    except Exception:
                        cover_restore = None

            if job_output_dir.exists():
                shutil.rmtree(job_output_dir, ignore_errors=True)
            job_output_dir.mkdir(parents=True, exist_ok=True)

            if cover_restore:
                temp_cover, target_cover = cover_restore
                try:
                    shutil.move(str(temp_cover), str(target_cover))
                except Exception:
                    with contextlib.suppress(FileNotFoundError):
                        temp_cover.unlink(missing_ok=True)
        else:
            job_output_dir.mkdir(parents=True, exist_ok=True)
        if resume_mode:
            _append_event(job, "♻️ Retomando conversão anterior - mantendo capítulos já gerados")

        book_safe_name = FileManager.sanitize_filename(title)
        zip_file = job_output_dir / f"{book_safe_name}.zip"
        zip_archive = zipfile.ZipFile(zip_file, "w", zipfile.ZIP_STORED)
        zip_open = True
        outputs: list[dict] = []
        completed_indices: set[int] = set()
        if resume_mode:
            existing_outputs, completed_indices = await _preload_existing_outputs(
                job, chapters, job_output_dir
            )
            if existing_outputs:
                outputs.extend(existing_outputs)
                _append_event(job, f"⏩ {len(existing_outputs)} capítulo(s) já estavam convertidos")
                job["chaptersCompleted"] = len(completed_indices)
                for completed_idx in completed_indices:
                    _complete_chapter_progress(completed_idx, broadcast=False)
                _update_job_progress(force_broadcast=True)

        if _should_abort_current_run("🛑 Conversão cancelada após processar capítulos"):
            return
        _update_job_activity(job, stage="output_ready")

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
            nonlocal engine_index, active_config
            if engine_index + 1 >= len(engine_chain):
                return False
            _append_event(job, f"🔁 {reason} → tentando fallback")

            while engine_index + 1 < len(engine_chain):
                engine_index += 1
                candidate = engine_chain[engine_index]
                engine_name = (candidate.engine or "").lower()
                if not engine_name or engine_name in unavailable_engines:
                    _append_event(job, f"   ↳ Engine '{candidate.engine}' indisponível, pulando")
                    continue
                _append_event(job, f"   ↳ Ativando engine '{candidate.engine}'...")
                active_config = candidate
                _append_event(
                    job,
                    f"   ✅ Agora usando {candidate.engine.upper()} ({candidate.voice or 'padrão'})",
                )
                return True
            return False

        zip_lock = asyncio.Lock()
        job_failed = {"value": False}
        edge_slow_mode = False
        edge_safe_profile = {
            "chunk_chars": EDGE_SAFE_CHUNK_CHARS,
            "max_segment_seconds": EDGE_SAFE_MAX_SEGMENT_SECONDS,
            "parallel_cap": EDGE_SAFE_CHAPTER_PARALLEL,
            "timeout_max": EDGE_SAFE_TIMEOUT_MAX,
        }
        edge_configs: list[ConversionConfig] = []
        _edge_cfg_seen: set[int] = set()
        for cfg in (
            config,
            active_config,
            auto_engine_pool.get("edge") if auto_engine_pool else None,
        ):
            if cfg and (cfg.engine or "").lower() == "edge":
                if id(cfg) not in _edge_cfg_seen:
                    edge_configs.append(cfg)
                    _edge_cfg_seen.add(id(cfg))

        def _apply_edge_slow_mode(reason: str) -> None:
            nonlocal parallel_slots, requested_slots, parallel_slots_cap, edge_slow_mode
            if not edge_auto_tune or edge_slow_mode:
                return
            edge_slow_mode = True
            job["_edgeSlowMode"] = True
            cap = max(1, int(edge_safe_profile["parallel_cap"] or 1))
            if parallel_slots_cap:
                cap = min(cap, parallel_slots_cap)
            parallel_slots_cap = cap
            requested_slots = min(requested_slots, cap)
            parallel_slots = min(parallel_slots, cap)
            job["parallelSlots"] = parallel_slots
            for cfg in edge_configs:
                cfg.edge_chunk_chars = min(
                    cfg.edge_chunk_chars or edge_safe_profile["chunk_chars"],
                    edge_safe_profile["chunk_chars"],
                )
                cfg.edge_max_segment_seconds = min(
                    cfg.edge_max_segment_seconds or edge_safe_profile["max_segment_seconds"],
                    edge_safe_profile["max_segment_seconds"],
                )
                cfg.edge_enable_parallel = False
            engine_pool.update_parallel_slots(parallel_slots)
            _append_event(
                job,
                f"🧯 Edge modo seguro: {reason} → chunk={edge_safe_profile['chunk_chars']} seg={edge_safe_profile['max_segment_seconds']}s paralelo={parallel_slots}",
            )

        def _available_auto_pool() -> dict[str, ConversionConfig]:
            if not auto_engine_pool:
                return {}
            return {
                name: cfg
                for name, cfg in auto_engine_pool.items()
                if name not in unavailable_engines
            }

        def _apply_auto_edge_profile(engine_obj: object) -> None:
            if not auto_edge_profile or not hasattr(engine_obj, "apply_speed_profile"):
                return
            if getattr(engine_obj, "_auto_profile_applied", False):
                return
            try:
                engine_obj.apply_speed_profile(
                    chunk_char_limit=auto_edge_profile.get("chunk_chars"),
                    max_segment_seconds=auto_edge_profile.get("max_segment_seconds"),
                    words_per_minute=auto_edge_profile.get("words_per_minute"),
                )
                setattr(engine_obj, "_auto_profile_applied", True)
            except Exception:
                pass

        chapter_attempts: dict[int, int] = {}
        retry_forever = _CHAPTER_RETRY_FOREVER
        max_retry_rounds = _CHAPTER_RETRY_ROUNDS
        max_chapter_attempts = max(1, 1 + max_retry_rounds)
        max_retry_rounds_label = "ilimitado" if retry_forever else str(max_retry_rounds)
        max_chapter_attempts_label = "ilimitado" if retry_forever else str(max_chapter_attempts)
        retrying_failed_chapters = False

        def _note_chapter_attempt(chapter_index: int) -> int:
            attempt = chapter_attempts.get(chapter_index, 0) + 1
            chapter_attempts[chapter_index] = attempt
            return attempt

        def _chapter_can_retry(chapter_index: int) -> bool:
            if retry_forever:
                return True
            return chapter_attempts.get(chapter_index, 0) < max_chapter_attempts

        def _reset_chapter_progress_tracking(chapter_index: int) -> None:
            chapter_processed = job.get("_chapterCharProcessed") or {}
            if chapter_index in chapter_processed:
                chapter_processed[chapter_index] = 0
                job["_chapterCharProcessed"] = chapter_processed
                job["processedChars"] = sum(int(value or 0) for value in chapter_processed.values())
            chapter_progress_ts = job.get("_chapterLastProgressUpdate") or {}
            chapter_progress_ts[chapter_index] = 0.0
            job["_chapterLastProgressUpdate"] = chapter_progress_ts
            _update_job_progress(force_broadcast=True)

        def _collect_failed_chapters() -> list[tuple[int, object]]:
            entries = job.get("chapterProgress") or []
            failed: list[tuple[int, object]] = []
            for entry in entries:
                if not isinstance(entry, dict):
                    continue
                if entry.get("status") != "failed":
                    continue
                idx = entry.get("index")
                if not isinstance(idx, int):
                    continue
                if idx < 1 or idx > len(chapters):
                    continue
                failed.append((idx, chapters[idx - 1]))
            return failed

        def _expected_output_path(chapter_index: int, chapter_obj) -> Path:
            chapter_name = getattr(chapter_obj, "name", f"Chapter {chapter_index}")
            safe_name = FileManager.sanitize_filename(chapter_name)
            return job_output_dir / f"{chapter_index:03d} - {safe_name}.mp3"

        def _collect_missing_chapters() -> list[tuple[int, object]]:
            missing: list[tuple[int, object]] = []
            for idx, chapter in enumerate(chapters, 1):
                output_file = _expected_output_path(idx, chapter)
                try:
                    if not output_file.exists() or output_file.stat().st_size <= 0:
                        missing.append((idx, chapter))
                except OSError:
                    missing.append((idx, chapter))
            return missing

        def _sync_soft_failures(failed_indices: set[int]) -> None:
            if not failed_indices:
                job["softFailures"] = []
                job.pop("softFailureCount", None)
                return
            soft_failures = job.get("softFailures") or []
            deduped: list[dict] = []
            seen: set[int] = set()
            for entry in reversed(soft_failures):
                if not isinstance(entry, dict):
                    continue
                idx = entry.get("index")
                if not isinstance(idx, int) or idx not in failed_indices or idx in seen:
                    continue
                deduped.append(entry)
                seen.add(idx)
            deduped.reverse()
            job["softFailures"] = deduped
            job["softFailureCount"] = len(deduped)

        def _mark_retry_round(round_number: int, total_failed: int) -> None:
            nonlocal parallel_slots, requested_slots, retrying_failed_chapters
            retrying_failed_chapters = True
            _append_event(
                job,
                f"🔁 Reprocessando {total_failed} capítulo(s) com falha (rodada {round_number}/{max_retry_rounds_label})",
            )
            job["statusHint"] = f"Reprocessando capítulos com falha ({total_failed})"
            requested_slots = 1
            parallel_slots = 1
            job["parallelSlots"] = parallel_slots
            engine_pool.update_parallel_slots(parallel_slots)
            for cfg in edge_configs:
                cfg.edge_enable_parallel = False
            _apply_edge_slow_mode("retry de capítulos falhos")
            _persist_job(job_id, force=True)

        async def convert_chapter(idx: int, chapter_obj) -> None:
            if job_failed["value"] or _should_abort_current_run():
                return

            attempt = _note_chapter_attempt(idx)

            chapter_name = getattr(chapter_obj, "name", f"Chapter {idx}")
            job["_currentChapterIndex"] = idx
            job["currentChapter"] = chapter_name
            job["parallelActive"] = job.get("parallelActive", 0) + 1
            job["statusHint"] = f"Capítulo {idx}/{len(chapters)}: {chapter_name}"
            start_time = time.time()
            heartbeat_stop = asyncio.Event()
            heartbeat_task: Optional[asyncio.Task] = None
            _update_job_activity(job, stage=f"chapter_{idx}_start")

            try:
                if attempt > 1:
                    _append_event(
                        job,
                        f"🔁 Reprocessando capítulo {idx}/{len(chapters)} (tentativa {attempt}/{max_chapter_attempts_label})",
                    )
                    # Set retrying status with info
                    _set_chapter_status(
                        job,
                        idx,
                        "retrying",
                        retry_count=attempt - 1,
                        max_retries=max_chapter_attempts,
                        retry_reason="Falha anterior",
                        param_adjustment="Parâmetros reduzidos",
                    )
                else:
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
                    _complete_chapter_progress(idx)
                    _update_job_activity(job, stage=f"chapter_{idx}_skipped")
                    return

                clean_text = TextFormattingProcessor.strip_inline_markdown(chapter_text)
                preview = _build_text_preview(clean_text)
                if preview:
                    _append_event(job, f"📝 Trecho: {preview}")

                def _progress_callback(segment_text: str, total_text_chars: int = 0) -> None:
                    _advance_chapter_progress(idx, segment_text, total_text_chars)

                # Streaming: create chunk directory and callback for progressive playback
                chunk_dir = _chapter_chunk_dir(job_id, idx, ensure=True)
                try:
                    # Clear previous chunks for this chapter
                    for old_file in chunk_dir.glob("chunk_*.mp3"):
                        old_file.unlink(missing_ok=True)
                    manifest_path = chunk_dir / "manifest.json"
                    if manifest_path.exists():
                        manifest_path.unlink(missing_ok=True)
                except Exception:
                    pass

                def _chunk_callback(
                    segment_index: int, temp_path: Path, segment_text: str = ""
                ) -> None:
                    """Save synthesized segment for streaming playback."""
                    try:
                        target = chunk_dir / f"chunk_{segment_index:04d}{temp_path.suffix}"
                        shutil.copy2(temp_path, target)
                        # Update manifest
                        manifest_path = chunk_dir / "manifest.json"
                        manifest: dict = {"jobId": job_id, "chapterIndex": idx, "chunks": []}
                        if manifest_path.exists():
                            try:
                                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                            except Exception:
                                manifest = {"jobId": job_id, "chapterIndex": idx, "chunks": []}
                        existing = [
                            e for e in (manifest.get("chunks") or []) if isinstance(e, dict)
                        ]
                        existing = [e for e in existing if e.get("index") != segment_index]
                        chunk_entry = {
                            "index": segment_index,
                            "file": target.name,
                            "url": f"/api/streams/{job_id}/chapters/{idx}/chunks/{segment_index}",
                        }
                        # Include segment text for reading mode
                        if segment_text:
                            chunk_entry["text"] = segment_text
                        existing.append(chunk_entry)
                        manifest["chunks"] = sorted(existing, key=lambda x: x.get("index", 0))
                        manifest["updatedAt"] = time.time()
                        manifest["baseUrl"] = f"/api/streams/{job_id}/chapters/{idx}"
                        manifest_path.write_text(
                            json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
                        )
                    except Exception as exc:
                        logger.debug("Chunk callback error for segment %d: %s", segment_index, exc)

                auto_order: list[str] = []
                attempted_auto: set[str] = set()
                engine_runtime: Optional[float] = None
                local_active_config = active_config
                local_engine_name = (
                    local_active_config.engine if local_active_config else config.engine
                ) or "auto"

                if auto_mode:
                    available_auto = _available_auto_pool()
                    if not available_auto:
                        _append_event(job, "❌ Nenhuma engine disponível no modo automático")
                        job_failed["value"] = True
                        return
                    if not telemetry_speeds:
                        summary = telemetry.summary()
                        telemetry_speeds.update(summary)
                    selected_engine, auto_order = _pick_auto_engine(
                        len(clean_text),
                        TextValidator.estimate_duration(clean_text),
                        available_auto,
                        telemetry_speeds=telemetry_speeds,
                        preferred_engine=preferred_auto_engine,
                    )
                    attempted_auto.add(selected_engine)
                    local_engine_name = selected_engine
                    local_active_config = available_auto[selected_engine]
                    _append_event(
                        job, f"⚡ AUTO: usando {selected_engine.upper()} para este capítulo"
                    )
                    est = TextValidator.estimate_duration(clean_text)
                    if est <= 0:
                        est = max(len(clean_text) / 15.0, 30.0)
                    _append_event(
                        job,
                        f"   ↳ Texto: {len(clean_text)} chars, estimado {_format_duration(est)}",
                    )

                estimated_seconds = TextValidator.estimate_duration(clean_text)
                if estimated_seconds <= 0:
                    estimated_seconds = max(len(clean_text) / 15.0, 30.0)

                retry_count = 0

                def _edge_retry_adjustments(edge_config, attempt: int) -> dict[str, float]:
                    # Research-based default: 8k chars
                    chunk = int(getattr(edge_config, "edge_chunk_chars", 8000) or 8000)
                    seg = float(getattr(edge_config, "edge_max_segment_seconds", 75) or 75)
                    factor = 0.7 if attempt <= 1 else 0.55
                    chunk = max(3000, int(chunk * factor))  # Min 3000 for retries
                    seg = max(50.0, min(seg, seg * factor))
                    return {
                        "chunk_char_limit": chunk,
                        "max_segment_seconds": seg,
                        "words_per_minute": 160,
                    }

                async def _maybe_retry(
                    *,
                    reason: str,
                    engine_label: str,
                    engine_obj,
                    engine_config,
                ) -> bool:
                    nonlocal retry_count, parallel_slots, engine_index
                    # Se existe engine de fallback disponível, prefira trocar em vez de insistir
                    if engine_index + 1 < len(engine_chain):
                        return False
                    if _CHAPTER_RETRY_MAX <= 0 or retry_count >= _CHAPTER_RETRY_MAX:
                        return False
                    retry_count += 1
                    backoff = _CHAPTER_RETRY_BACKOFF_SECONDS * (1 + 0.5 * (retry_count - 1))
                    if (engine_label or "").lower() == "edge":
                        _apply_edge_slow_mode(reason)
                        adjustments = _edge_retry_adjustments(engine_config, retry_count)
                        if hasattr(engine_obj, "apply_speed_profile"):
                            try:
                                engine_obj.apply_speed_profile(**adjustments)
                            except Exception:
                                pass
                        engine_config.edge_chunk_chars = int(adjustments["chunk_char_limit"])
                        engine_config.edge_max_segment_seconds = int(
                            adjustments["max_segment_seconds"]
                        )
                        engine_config.edge_enable_parallel = False
                        config.edge_chunk_chars = engine_config.edge_chunk_chars
                        config.edge_max_segment_seconds = engine_config.edge_max_segment_seconds
                        config.edge_enable_parallel = engine_config.edge_enable_parallel
                        _append_event(
                            job,
                            f"🔧 Edge fallback: chunk={engine_config.edge_chunk_chars} seg={engine_config.edge_max_segment_seconds}s paralelo=off",
                        )
                    elif (engine_label or "").lower().startswith("coqui"):
                        if hasattr(engine_config, "coqui_chunk_chars"):
                            old_chunk = int(getattr(engine_config, "coqui_chunk_chars") or 0)
                            new_chunk = max(800, int(max(old_chunk, 1200) * 0.75))
                            engine_config.coqui_chunk_chars = new_chunk
                            config.coqui_chunk_chars = new_chunk
                            _append_event(
                                job,
                                f"🔧 Coqui fallback: chunk={new_chunk} (antes {old_chunk or 'auto'})",
                            )
                    if parallel_slots > 1:
                        parallel_slots = max(1, parallel_slots - 1)
                        engine_pool.update_parallel_slots(parallel_slots)
                        job["parallelSlots"] = parallel_slots
                        _append_event(
                            job,
                            f"⚙️ Reduzindo paralelismo para {parallel_slots} após {reason}",
                        )
                    if backoff > 0:
                        await asyncio.sleep(backoff)
                    _append_event(
                        job,
                        f"🔁 Tentando novamente ({retry_count}/{_CHAPTER_RETRY_MAX}) após {reason}",
                    )
                    return True

                async def _chapter_heartbeat_loop() -> None:
                    progress_tick = 5.0
                    last_log_ts = start_time
                    try:
                        while True:
                            try:
                                await asyncio.wait_for(
                                    heartbeat_stop.wait(),
                                    timeout=progress_tick,
                                )
                                break
                            except asyncio.TimeoutError:
                                now = time.time()
                                elapsed = now - start_time
                                if (now - last_log_ts) < _CHAPTER_HEARTBEAT_SECONDS:
                                    continue
                                last_log_ts = now
                                engine_label = (
                                    local_active_config.engine
                                    if local_active_config
                                    else config.engine
                                ) or "auto"
                                in_progress = _format_hms(elapsed)
                                remaining = max(0.0, estimated_seconds - elapsed)
                                hint = f"Capítulo {idx}/{len(chapters)}: {chapter_name} há {_format_duration(elapsed)}"
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
                    if _should_abort_current_run(
                        f"🛑 Conversão cancelada durante o capítulo {chapter_name}"
                    ):
                        return

                    engine_name = (
                        local_engine_name
                        or (local_active_config.engine if local_active_config else config.engine)
                        or "auto"
                    ).lower()
                    synth_started = time.time()
                    last_stage_timestamp = synth_started
                    chapter_timeout = _resolve_chapter_timeout(estimated_seconds)
                    if edge_slow_mode and engine_name == "edge":
                        chapter_timeout = min(
                            chapter_timeout, float(edge_safe_profile["timeout_max"])
                        )
                    try:
                        async with engine_pool.use(engine_name) as (engine_config, engine_obj):
                            local_active_config = engine_config
                            local_engine_name = (engine_config.engine or engine_name).lower()
                            if auto_mode and local_engine_name == "edge" and not edge_slow_mode:
                                _apply_auto_edge_profile(engine_obj)
                            if (
                                edge_slow_mode
                                and (engine_config.engine or engine_name).lower() == "edge"
                            ):
                                if hasattr(engine_obj, "apply_speed_profile"):
                                    try:
                                        engine_obj.apply_speed_profile(
                                            chunk_char_limit=edge_safe_profile["chunk_chars"],
                                            max_segment_seconds=edge_safe_profile[
                                                "max_segment_seconds"
                                            ],
                                            words_per_minute=160,
                                        )
                                    except Exception:
                                        pass
                                if hasattr(engine_obj, "_enable_parallel"):
                                    with contextlib.suppress(Exception):
                                        setattr(engine_obj, "_enable_parallel", False)
                                        setattr(engine_obj, "_parallel_slots", 1)
                            tts_path, needs_transcode = _resolve_tts_output(
                                output_file, engine_config.engine
                            )
                            try:
                                try:
                                    synth_task = engine_obj.synthesize_async(
                                        clean_text,
                                        tts_path,
                                        progress_callback=_progress_callback,
                                        chunk_callback=_chunk_callback,
                                    )
                                except TypeError:
                                    # Fallback for engines that don't support callbacks
                                    synth_task = engine_obj.synthesize_async(clean_text, tts_path)
                                await asyncio.wait_for(synth_task, timeout=chapter_timeout)
                                last_stage_timestamp = time.time()
                            except asyncio.TimeoutError:
                                use_engine = engine_config.engine or engine_name or "desconhecido"
                                _append_event(
                                    job,
                                    f"   ⚠️ {chapter_name}: tempo limite de {int(chapter_timeout)}s excedido em {use_engine}",
                                )
                                job["statusHint"] = (
                                    f"Capítulo {idx}/{len(chapters)} atrasado em {use_engine.upper()} (timeout)"
                                )
                                if await _maybe_retry(
                                    reason=f"timeout em {use_engine}",
                                    engine_label=use_engine,
                                    engine_obj=engine_obj,
                                    engine_config=engine_config,
                                ):
                                    continue
                                if auto_mode:
                                    available_auto = _available_auto_pool()
                                    next_engine = _next_auto_engine(
                                        auto_order, attempted_auto, available_auto
                                    )
                                    if next_engine:
                                        attempted_auto.add(next_engine)
                                        local_engine_name = next_engine
                                        local_active_config = available_auto[next_engine]
                                        _append_event(
                                            job,
                                            f"   ↳ AUTO: alternando para {next_engine.upper()} após timeout",
                                        )
                                        continue
                                if _switch_to_next_engine(
                                    f"Sintetizador {use_engine.upper()} ficou preso por {int(chapter_timeout)}s"
                                ):
                                    local_active_config = active_config
                                    local_engine_name = (
                                        active_config.engine if active_config else config.engine
                                    ) or "auto"
                                    continue
                                if _record_chapter_failure(
                                    job,
                                    engine_obj,
                                    chapter_name,
                                    "tempo limite excedido",
                                    chapter_index=idx,
                                    fatal=False,
                                ):
                                    job_failed["value"] = True
                                return
                            except Exception as exc:
                                if await _maybe_retry(
                                    reason=f"erro em {engine_config.engine if engine_config else 'engine'}",
                                    engine_label=(
                                        engine_config.engine if engine_config else engine_name
                                    ),
                                    engine_obj=engine_obj,
                                    engine_config=engine_config,
                                ):
                                    continue
                                if auto_mode:
                                    available_auto = _available_auto_pool()
                                    next_engine = _next_auto_engine(
                                        auto_order, attempted_auto, available_auto
                                    )
                                    if next_engine:
                                        attempted_auto.add(next_engine)
                                        local_engine_name = next_engine
                                        local_active_config = available_auto[next_engine]
                                        _append_event(
                                            job,
                                            f"   ↳ AUTO: alternando para {next_engine.upper()} após erro ({exc})",
                                        )
                                        continue
                                if _switch_to_next_engine(
                                    f"Engine {engine_config.engine if engine_config else config.engine} falhou ({exc})"
                                ):
                                    local_active_config = active_config
                                    local_engine_name = (
                                        active_config.engine if active_config else config.engine
                                    ) or "auto"
                                    continue
                                if _record_chapter_failure(
                                    job,
                                    engine_obj,
                                    chapter_name,
                                    exc,
                                    chapter_index=idx,
                                    fatal=False,
                                ):
                                    job_failed["value"] = True
                                return

                            target_file = output_file
                            if needs_transcode:
                                converted = await AudioProcessor.convert_to_mp3(
                                    tts_path,
                                    output_file,
                                    bitrate=config.bitrate,
                                )
                                if not converted:
                                    with contextlib.suppress(OSError):
                                        tts_path.unlink(missing_ok=True)
                                    if auto_mode:
                                        available_auto = _available_auto_pool()
                                        next_engine = _next_auto_engine(
                                            auto_order, attempted_auto, available_auto
                                        )
                                        if next_engine:
                                            attempted_auto.add(next_engine)
                                            local_engine_name = next_engine
                                            local_active_config = available_auto[next_engine]
                                            _append_event(
                                                job,
                                                f"   ↳ AUTO: alternando para {next_engine.upper()} após falha na conversão WAV→MP3",
                                            )
                                            continue
                                    if _switch_to_next_engine("Conversão WAV→MP3 falhou"):
                                        local_active_config = active_config
                                        local_engine_name = (
                                            active_config.engine if active_config else config.engine
                                        ) or "auto"
                                        continue
                                    if _record_chapter_failure(
                                        job,
                                        engine_obj,
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
                                    available_auto = _available_auto_pool()
                                    next_engine = _next_auto_engine(
                                        auto_order, attempted_auto, available_auto
                                    )
                                    if next_engine:
                                        attempted_auto.add(next_engine)
                                        local_engine_name = next_engine
                                        local_active_config = available_auto[next_engine]
                                        _append_event(
                                            job, "   ↳ AUTO: áudio vazio; tentando outra engine"
                                        )
                                        continue
                                if _switch_to_next_engine("Áudio vazio ou inexistente"):
                                    local_active_config = active_config
                                    local_engine_name = (
                                        active_config.engine if active_config else config.engine
                                    ) or "auto"
                                    continue
                                if _record_chapter_failure(
                                    job,
                                    engine_obj,
                                    chapter_name,
                                    "áudio não foi gerado pelo serviço de voz",
                                    chapter_index=idx,
                                    fatal=False,
                                ):
                                    job_failed["value"] = True
                                return
                    except Exception as exc:
                        if engine_name:
                            unavailable_engines.add(engine_name)
                        if auto_mode:
                            available_auto = _available_auto_pool()
                            next_engine = _next_auto_engine(
                                auto_order, attempted_auto, available_auto
                            )
                            if next_engine:
                                attempted_auto.add(next_engine)
                                local_engine_name = next_engine
                                local_active_config = available_auto[next_engine]
                                _append_event(
                                    job,
                                    f"   ↳ AUTO: alternando para {next_engine.upper()} após falha ao iniciar ({exc})",
                                )
                                continue
                        if _switch_to_next_engine(
                            f"Engine {(engine_name or '').upper()} indisponível ({exc})"
                        ):
                            local_active_config = active_config
                            local_engine_name = (
                                active_config.engine if active_config else config.engine
                            ) or "auto"
                            continue
                        if _record_chapter_failure(
                            job,
                            None,
                            chapter_name,
                            exc,
                            chapter_index=idx,
                            fatal=False,
                        ):
                            job_failed["value"] = True
                        return
                    break

                engine_runtime = max((last_stage_timestamp - synth_started), 0.001)
                duration_seconds = await _get_audio_duration(output_file)
                chapter_elapsed = time.time() - start_time

                _append_event(
                    job, f"✅ Concluído: {output_file.name} (em {_format_hms(chapter_elapsed)})"
                )

                # Add download URL to chapter progress
                chapter_output = {
                    "name": output_file.name,
                    "url": f"/api/outputs/{job_id}/{output_file.name}",
                    "durationSeconds": round(duration_seconds, 2),
                    "sizeBytes": output_file.stat().st_size,
                }
                # Include retry count if chapter required retries
                retry_count = attempt - 1 if attempt > 1 else None
                _set_chapter_status(
                    job,
                    idx,
                    "completed",
                    download_url=chapter_output["url"],
                    retry_count=retry_count,
                )
                _refresh_chapter_completion()
                _complete_chapter_progress(idx)
                _update_job_activity(job, stage=f"chapter_{idx}_completed")

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
                    _append_event(
                        job,
                        f"⏱️ {local_active_config.engine.upper()} ≈ {chars_per_second:.1f} chars/s",
                    )
                    entry = job["chapterProgress"][idx - 1]
                    if isinstance(entry, dict):
                        entry["elapsedSeconds"] = round(chapter_elapsed, 2)
                        entry["charsPerSecond"] = round(chars_per_second, 1)
                    if (
                        edge_auto_tune
                        and (local_active_config.engine or "").lower() == "edge"
                        and (
                            chars_per_second < EDGE_MIN_CHARS_PER_SECOND
                            or (
                                estimated_seconds > 0
                                and chapter_elapsed
                                > (estimated_seconds * EDGE_SLOW_RATIO_THRESHOLD)
                            )
                        )
                    ):
                        _apply_edge_slow_mode(f"velocidade baixa ({chars_per_second:.1f} chars/s)")
            finally:
                heartbeat_stop.set()
                if heartbeat_task:
                    with contextlib.suppress(asyncio.CancelledError):
                        await heartbeat_task
                job.pop("statusHint", None)
                job["parallelActive"] = max(job.get("parallelActive", 1) - 1, 0)

        _append_event(job, "")
        _append_event(job, "🚀 Iniciando conversão dos capítulos...")
        _persist_job(job_id, force=True)  # Persist before starting conversion

        last_parallel_update = 0.0
        last_health_check = 0.0
        health_check_interval = float(
            job.get("healthCheckIntervalSeconds") or _HEALTHCHECK_INTERVAL_SECONDS
        )
        health_check_interval = max(10.0, min(300.0, health_check_interval))
        health_slow_edge_cps = float(
            job.get("healthCheckSlowEdgeCps") or _HEALTHCHECK_SLOW_EDGE_CPS
        )
        health_slow_cps = float(job.get("healthCheckSlowCps") or _HEALTHCHECK_SLOW_CPS)
        health_high_cpu = float(job.get("healthCheckHighCpu") or _HEALTHCHECK_HIGH_CPU)
        health_high_mem = float(job.get("healthCheckHighMem") or _HEALTHCHECK_HIGH_MEM)
        health_ok_cpu = float(job.get("healthCheckOkCpu") or _HEALTHCHECK_OK_CPU)
        health_ok_mem = float(job.get("healthCheckOkMem") or _HEALTHCHECK_OK_MEM)
        health_slow_streak_limit = int(job.get("healthCheckSlowStreak") or _HEALTHCHECK_SLOW_STREAK)
        health_slow_streak_limit = max(1, min(6, health_slow_streak_limit))
        if health_ok_cpu >= health_high_cpu:
            health_ok_cpu = max(10.0, health_high_cpu - 5.0)
        if health_ok_mem >= health_high_mem:
            health_ok_mem = max(10.0, health_high_mem - 5.0)
        slow_streak = 0

        def _compute_parallel_slots() -> int:
            if force_sequential or retrying_failed_chapters:
                return 1
            target_slots = _determine_parallel_slots(requested_slots)
            if edge_cap > 0:
                target_slots = min(target_slots, edge_cap)
            if parallel_slots_cap:
                target_slots = min(target_slots, parallel_slots_cap)
            active_jobs = sum(1 for job_data in jobs.values() if job_data.get("state") == "running")
            if active_jobs > 1:
                target_slots = max(1, target_slots // active_jobs)
            return max(1, target_slots)

        def _maybe_adjust_parallel_slots(force: bool = False) -> None:
            nonlocal parallel_slots, last_parallel_update
            now = time.time()
            if not force and (now - last_parallel_update) < 3:
                return
            new_slots = _compute_parallel_slots()
            if new_slots != parallel_slots:
                _append_event(job, f"⚙️ Ajustando paralelismo {parallel_slots}→{new_slots}")
                parallel_slots = new_slots
                job["parallelSlots"] = new_slots
                engine_pool.update_parallel_slots(new_slots)
                _persist_job(job_id, force=False)
            last_parallel_update = now

        def _resolve_recent_speed(engine_name: str) -> float:
            entries = job.get("chapterProgress") or []
            for entry in reversed(entries):
                if isinstance(entry, dict):
                    value = entry.get("charsPerSecond")
                    if isinstance(value, (int, float)) and value > 0:
                        return float(value)
            summary = telemetry.summary()
            engine_key = (engine_name or "").lower()
            stats = summary.get(engine_key) or {}
            return float(stats.get("avg_chars_per_second") or 0.0)

        def _maybe_health_check(force: bool = False) -> None:
            nonlocal \
                parallel_slots, \
                last_health_check, \
                slow_streak, \
                parallel_slots_cap, \
                requested_slots
            now = time.time()
            if not force and (now - last_health_check) < health_check_interval:
                return
            last_health_check = now
            stats = system_monitor.latest() or {}
            cpu_percent = float((stats.get("cpu") or {}).get("percent") or 0.0)
            mem_percent = float((stats.get("memory") or {}).get("percent") or 0.0)
            engine_label = (
                (active_config.engine if active_config else config.engine)
                or job.get("engine")
                or "auto"
            ).lower()
            recent_speed = _resolve_recent_speed(engine_label)
            slow_threshold = health_slow_edge_cps if engine_label == "edge" else health_slow_cps
            is_slow = recent_speed > 0 and slow_threshold > 0 and recent_speed < slow_threshold

            if is_slow:
                slow_streak += 1
            else:
                slow_streak = max(0, slow_streak - 1)

            if slow_streak >= health_slow_streak_limit and engine_label == "edge":
                _apply_edge_slow_mode(f"healthcheck velocidade baixa ({recent_speed:.1f} chars/s)")
            elif (
                slow_streak >= health_slow_streak_limit
                and parallel_slots > 1
                and (cpu_percent > health_high_cpu or mem_percent > health_high_mem)
            ):
                new_slots = max(1, parallel_slots - 1)
                if new_slots != parallel_slots:
                    _append_event(
                        job, f"🧪 Healthcheck: reduzindo paralelismo {parallel_slots}→{new_slots}"
                    )
                    parallel_slots = new_slots
                    job["parallelSlots"] = new_slots
                    engine_pool.update_parallel_slots(new_slots)

            if cpu_percent < health_ok_cpu and mem_percent < health_ok_mem and not force_sequential:
                desired = _compute_parallel_slots()
                if max_performance:
                    desired = max(desired, min(_CHAPTER_PARALLEL_MAX, parallel_slots + 1))
                if desired != parallel_slots:
                    _append_event(
                        job, f"🧪 Healthcheck: ajustando paralelismo {parallel_slots}→{desired}"
                    )
                    parallel_slots = desired
                    job["parallelSlots"] = desired
                    engine_pool.update_parallel_slots(desired)
            _persist_job(job_id, force=False)

        pending_chapters = [
            (idx, chapter)
            for idx, chapter in enumerate(chapters, 1)
            if idx not in completed_indices
        ]
        retry_round = 0
        while pending_chapters:
            if retry_round > 0:
                _mark_retry_round(retry_round, len(pending_chapters))
            else:
                retrying_failed_chapters = False
            _update_job_activity(job, stage="conversion_loop")
            running_tasks: set[asyncio.Task] = set()
            cursor = 0
            _maybe_adjust_parallel_slots(force=True)

            while cursor < len(pending_chapters) or running_tasks:
                abort_requested = job.get("cancelRequested") or job.get("_run_token") != run_token
                if not job_failed["value"] and not abort_requested:
                    _maybe_adjust_parallel_slots()
                    while len(running_tasks) < parallel_slots and cursor < len(pending_chapters):
                        idx, chapter = pending_chapters[cursor]
                        cursor += 1
                        running_tasks.add(asyncio.create_task(convert_chapter(idx, chapter)))
                if abort_requested and not running_tasks:
                    break
                if not running_tasks:
                    break
                done, running_tasks = await asyncio.wait(
                    running_tasks,
                    timeout=1.0,
                    return_when=asyncio.FIRST_COMPLETED,
                )
                _maybe_health_check()
                if not done:
                    continue
                for task in done:
                    try:
                        task.result()
                    except asyncio.CancelledError:
                        pass
                    except Exception as exc:
                        job_failed["value"] = True
                        _append_event(job, f"❌ Erro inesperado ao converter capítulo: {exc}")
                        _persist_job(job_id, force=True)
                _maybe_adjust_parallel_slots()

            if job.get("cancelRequested") or job.get("_run_token") != run_token:
                break
            if job_failed["value"]:
                break

            failed_chapters = _collect_failed_chapters()
            missing_chapters = _collect_missing_chapters()
            if missing_chapters:
                expected_count = len(chapters)
                actual_count = len(
                    [
                        path
                        for path in job_output_dir.glob("*.mp3")
                        if not path.name.lower().startswith("tmp")
                    ]
                )
                _append_event(
                    job,
                    f"🔍 Verificando arquivos finais: {actual_count}/{expected_count} encontrados; reprocessando pendentes",
                )
                failed_index_set = {idx for idx, _ in failed_chapters}
                for idx, chapter in missing_chapters:
                    if idx in failed_index_set:
                        continue
                    _set_chapter_status(job, idx, "failed")
                    failed_chapters.append((idx, chapter))
            failed_indices = {idx for idx, _ in failed_chapters}
            _sync_soft_failures(failed_indices)
            if not failed_chapters:
                break

            retryable = [
                (idx, chapter) for idx, chapter in failed_chapters if _chapter_can_retry(idx)
            ]
            if retryable and (retry_forever or retry_round < max_retry_rounds):
                retry_round += 1
                for idx, _ in retryable:
                    _set_chapter_status(job, idx, "pending")
                    _reset_chapter_progress_tracking(idx)
                if retry_forever and _CHAPTER_RETRY_BACKOFF_SECONDS > 0:
                    await asyncio.sleep(_CHAPTER_RETRY_BACKOFF_SECONDS)
                pending_chapters = retryable
                continue

            preview = ", ".join(
                f"#{idx} {getattr(chapter, 'name', f'Capítulo {idx}')}"
                for idx, chapter in failed_chapters[:3]
            )
            if len(failed_chapters) > 3:
                preview += f" … (+{len(failed_chapters) - 3})"
            failure_message = f"{len(failed_chapters)} capítulo(s) falharam após {max_chapter_attempts_label} tentativa(s)."
            _append_event(job, f"❌ {failure_message}")
            if preview:
                _append_event(job, f"   ↳ Capítulos: {preview}")
            job["state"] = "failed"
            job["error"] = failure_message
            job["completedAt"] = time.time()
            job["completedAtIso"] = _utcnow_iso()
            job["parallelActive"] = 0
            _persist_job(job_id, force=True)
            _persist_job_log(job_id, job)
            return

        retrying_failed_chapters = False

        _cleanup_output_directory(job_output_dir)
        _update_job_activity(job, stage="chapters_done")

        if _should_abort_current_run("🛑 Conversão cancelada durante o processamento"):
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
        _update_job_activity(job, stage="building_zip")
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
        _update_job_activity(job, stage="outputs_ready")

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
                        mp3_path, object_key=f"{job_id}/{asset['name']}", ttl_hours=48
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
                zip_file, object_key=f"{job_id}/{zip_file.name}", ttl_hours=48
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
        job["completedAtIso"] = _utcnow_iso()
        job["totalElapsedSeconds"] = int(total_elapsed)
        _update_job_activity(job, stage="completed_success")
        _append_event(job, "")
        _append_event(job, "✅ Conversão finalizada com sucesso")
        _append_event(job, f"⏱️ Tempo total de conversão: {_format_hms(total_elapsed)}")
        _append_event(job, f"📁 Arquivo disponível: {zip_file.name} ({len(chapters)} capítulos)")
        job["parallelActive"] = 0
        job["resumeRequested"] = False
        _persist_job(job_id)

        # **CRITICAL**: Ensure final broadcast so frontend transitions to step 3
        _schedule_job_broadcast(job_id, job)

        if job.get("_purgeRequested"):
            _purge_job_data(job_id, job)
            return

        # KEEP job in memory and disk for at least 1 hour after completion
        # This prevents 404 errors when frontend is still polling
        # Jobs will be cleaned up by periodic cleanup task
        logger.info(f"Job {job_id} completed successfully - keeping in memory for frontend access")

    except Exception as exc:  # pragma: no cover - defensive handling
        job["state"] = "failed"
        job["error"] = str(exc)
        job["completedAt"] = time.time()  # Timestamp for cleanup
        job["completedAtIso"] = _utcnow_iso()
        _update_job_activity(job, stage="failed")
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
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
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


def _set_chapter_status(
    job: dict,
    chapter_index: Optional[int],
    status: str,
    download_url: Optional[str] = None,
    *,
    retry_count: Optional[int] = None,
    max_retries: Optional[int] = None,
    retry_reason: Optional[str] = None,
    param_adjustment: Optional[str] = None,
) -> None:
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
                # Retry information
                if retry_count is not None:
                    entry["retryCount"] = retry_count
                if max_retries is not None:
                    entry["maxRetries"] = max_retries
                if retry_reason is not None:
                    entry["retryReason"] = retry_reason
                if param_adjustment is not None:
                    entry["paramAdjustment"] = param_adjustment
                # Clear retry info when completed
                if status == "completed":
                    entry.pop("retryReason", None)
                    entry.pop("paramAdjustment", None)
    if isinstance(entries, list):
        processing = sum(
            1
            for entry in entries
            if isinstance(entry, dict) and entry.get("status") in ("processing", "retrying")
        )
        job["parallelActive"] = processing


def _set_engine_status(
    job: dict,
    engine: str,
    status: str,
    message: Optional[str] = None,
    progress: Optional[float] = None,
) -> None:
    """Update engine loading/initialization status in job."""
    job["engineStatus"] = {
        "engine": engine,
        "status": status,
        "message": message,
        "progress": progress,
    }
    _schedule_job_broadcast(job.get("jobId"), job)


async def _preload_existing_outputs(
    job: dict, chapters: list, job_output_dir: Path
) -> tuple[list[dict], set[int]]:
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
        download_url = f"/api/outputs/{job_id}/{output_file.name}" if job_id else output_file.name
        entry = {
            "name": output_file.name,
            "url": download_url,
            "durationSeconds": round(duration, 2),
            "sizeBytes": output_file.stat().st_size,
        }
        existing_outputs.append(entry)
        completed_indices.add(idx)
        _set_chapter_status(job, idx, "completed", download_url=download_url)
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


def _prepare_chapters(
    reader: EbookReader, config: ConversionConfig, selectors: Optional[str] = None
) -> list:
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
        raw_selectors = [
            token.strip() for token in re.split(r"[\s,;]+", selectors) if token.strip()
        ]
        if raw_selectors:
            try:
                filtered_items, filtered = converter_app._filter_structure_selection(
                    structure_items, raw_selectors
                )
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
