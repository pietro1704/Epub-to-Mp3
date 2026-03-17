#!/usr/bin/env python3
"""FastAPI server for converting EPUBs into spoken MP3 chapters."""

from __future__ import annotations

# **PERFORMANCE**: Apply system optimizations BEFORE heavy imports
import os

# Auto-accept Coqui TTS license (CPML non-commercial) — required for HF Space
os.environ.setdefault("COQUI_TOS_AGREED", "1")
# **CPU FIRST**: Force CPU mode in environments without GPU (HF Spaces zero-GPU)
os.environ.setdefault("CUDA_VISIBLE_DEVICES", "")
os.environ.setdefault("FORCE_CUDA", "0")
os.environ.setdefault("FORCE_CPU_ONLY", "1")
os.environ.setdefault("TTS_USE_GPU", "0")

# Configure performance optimizations before any imports
try:
    from performance_config import apply_all_optimizations

    apply_all_optimizations()
except ImportError:
    print("⚠️ [Performance] Optimization module not found")

import asyncio
import contextlib
import hashlib
import json
import logging
import re
import shutil
import sys
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
from src.auto_tuner import AutoTuner
from src.benchmark_profile import recommend_parallel_slots
from src.cache_manager import CacheManager
from src.chapter_utils import MIN_DUPLICATE_CHARS, deduplicate_chapters_by_content
from src.config import CACHE_DIR, ConversionConfig
from src.ebook_reader import EbookReader
from src.engine_pool import JobEnginePool, ResourceSnapshot
from src.hardware_detector import HardwareDetector, HardwareProfile
from src.job_manager import JobManager
from src.language import LanguageProfile
from src.paths import (
    JOB_INPUTS_DIR,
    JOBS_DIR,
    OUTPUT_DIR,
    PERSISTENT_ROOT,
    SOURCE_BACKUPS_DIR,
    UPLOADS_DIR,
)
from src.telemetry import TelemetryRecorder
from src.text_formatting import TextFormattingProcessor
from src.tts.coqui_guard import is_coqui_supported_environment
from src.tts.edge_engine import reset_adaptive_settings
from src.tts.factory import TTSFactory
from src.tts.kokoro_guard import load_kokoro_supports_language
from src.tts.piper_guard import is_piper_supported_environment
from src.tts.spark_guard import is_spark_supported_environment
from src.utils import AudioProcessor, FileManager, TextValidator, TimeFormatter


def _detect_test_environment() -> bool:
    if os.environ.get("PYTEST_CURRENT_TEST"):
        return True
    try:
        argv = sys.argv
    except Exception:
        argv = []
    for arg in argv[:1]:
        if arg and "pytest" in arg.lower():
            return True
    return False


_IS_TEST_ENV = _detect_test_environment()

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

    # Initialize auto-tuner (detects HW and network, sets performance flags automatically)
    global _auto_tuner
    if os.getenv("ENABLE_AUTO_TUNING", "1").lower() in ("1", "true", "yes"):
        _auto_tuner = AutoTuner(verbose=True)
        try:
            # Do not measure network at server startup (may block on timeout)
            await _auto_tuner.auto_configure(force=False, measure_network=False)
        except Exception as exc:
            logger.warning(f"Auto-tuning failed (using defaults): {exc}")

    if not _job_watchdog_task:
        _job_watchdog_task = asyncio.create_task(_job_watchdog())

    # On HF Spaces, ping the health endpoint every 10 minutes to prevent the
    # Space from hibernating and losing the in-memory job index.  The /data
    # directory is persistent, so completed outputs survive a restart, but a
    # sleeping Space means the user's browser gets no response when polling.
    if os.getenv("SPACE_ID"):
        _hf_keepalive_task = asyncio.create_task(_hf_keepalive())
        logger.info("✅ HF Space keep-alive task started (10 min interval)")

    try:
        from health_monitor import get_system_monitor_adapter

        global system_monitor
        system_monitor = get_system_monitor_adapter()
        system_monitor.start()
        logger.info("✅ Health Monitor started")
    except Exception as e:
        logger.warning(f"⚠️ Failed to start Health Monitor: {e}")

    try:
        from auto_recovery import start_auto_recovery

        recovery = start_auto_recovery()
        recovery.set_activity_provider(_has_active_jobs)
        logger.info("✅ Auto-Recovery System started")
    except Exception as e:
        logger.warning(f"⚠️ Failed to start Auto-Recovery: {e}")

    # Mark process as a web server so session_logger picks the right mode
    os.environ.setdefault("SERVER_MODE", "1")

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
# **PERFORMANCE**: Use the same aggressive settings as the CLI
# Disable conservative auto-tune for maximum speed
EDGE_AUTO_TUNE = os.getenv("EDGE_AUTO_TUNE", "false").strip().lower() in {"1", "true", "yes", "on"}
# On HF Spaces, Edge-TTS shares egress IPs and runs at 60-120 chars/s even when
# "working" (vs 200+ locally). Use tighter thresholds so slow mode + engine
# switch trigger sooner rather than letting each chapter crawl for 3-4 minutes.
_hf_mode = bool(os.getenv("SPACE_ID"))
EDGE_MIN_CHARS_PER_SECOND = float(
    os.getenv("EDGE_MIN_CHARS_PER_SECOND", "100" if _hf_mode else "45") or "45"
)
EDGE_SLOW_RATIO_THRESHOLD = float(
    os.getenv("EDGE_SLOW_RATIO_THRESHOLD", "1.5" if _hf_mode else "2.5") or "2.5"
)
# Research-based (Jan 2026): 8k default (safe range 3k-8k, >15k = incomplete)
EDGE_SAFE_CHUNK_CHARS = max(3000, int(os.getenv("EDGE_SAFE_CHUNK_CHARS", "8000") or "8000"))
EDGE_SAFE_MAX_SEGMENT_SECONDS = max(
    30, int(os.getenv("EDGE_SAFE_MAX_SEGMENT_SECONDS", "300") or "300")
)
# **PERFORMANCE**: Increase chapter parallelism to match the CLI
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
# On HF Spaces, output files live on /data (persistent across restarts), so we
# keep them much longer by default. Override via COMPLETED_JOB_TTL_HOURS env var.
_DEFAULT_TTL_HOURS = 48 if os.getenv("SPACE_ID") else 4
COMPLETED_JOB_TTL_HOURS = float(
    os.getenv("COMPLETED_JOB_TTL_HOURS", str(_DEFAULT_TTL_HOURS)) or _DEFAULT_TTL_HOURS
)
CLEANUP_INTERVAL_SECONDS = 300  # Run cleanup every 5 minutes
TELEMETRY_RETENTION_HOURS = max(
    24, int(os.getenv("TELEMETRY_RETENTION_HOURS", "720") or "720")
)  # 30 days

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
    # Dev-friendly local origins (localhost, loopback and private LAN IPs)
    allow_origin_regex=(
        r"^https?://("
        r"localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]|::1|"
        r"10(?:\.\d{1,3}){3}|"
        r"192\.168(?:\.\d{1,3}){2}|"
        r"172\.(?:1[6-9]|2\d|3[0-1])(?:\.\d{1,3}){2}"
        r")(:\d+)?$"
    ),
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


output_dir = OUTPUT_DIR
persistent_root = PERSISTENT_ROOT

uploads_dir = UPLOADS_DIR
job_inputs_dir = JOB_INPUTS_DIR
source_backups_dir = SOURCE_BACKUPS_DIR

# Persistent cache for extracted chapter texts — survives restarts
persistent_cache_dir = CACHE_DIR
persistent_cache_dir.mkdir(exist_ok=True, parents=True)

# CacheManager singleton with persistent directory
_persistent_cache_manager: Optional[CacheManager] = None


def get_cache_manager() -> CacheManager:
    """Return the CacheManager singleton using the persistent directory."""
    global _persistent_cache_manager
    if _persistent_cache_manager is None:
        _persistent_cache_manager = CacheManager(cache_dir=persistent_cache_dir)
    return _persistent_cache_manager


cover_cache_dir = output_dir / ".cover_cache"
cover_cache_dir.mkdir(exist_ok=True, parents=True)
cover_index_path = cover_cache_dir / "index.json"


# Helpers to resolve per-book/per-engine paths (supports legacy job-id layout)
def _book_slug(title: Optional[str], fallback: Optional[str] = None) -> str:
    base = title or fallback or "book"
    try:
        stem = Path(base).stem if base and "." in base else base
    except Exception:
        stem = base
    return FileManager.sanitize_filename(stem)


def _job_output_dir(job_id: str, job: Optional[dict] = None, ensure: bool = False) -> Path:
    """Resolve the canonical output directory for a job.

    The first successful resolution persists the location on the job payload so
    follow-up calls (like streaming endpoints) read/write from the same place.
    When no metadata is available we fallback to the legacy `<output>/<job_id>`
    layout to avoid breaking older jobs.
    """

    legacy_dir = output_dir / job_id
    job_data = job or jobs.get(job_id) or job_manager.load_job(job_id)
    target: Optional[Path] = None

    if job_data:
        stored = job_data.get("outputDir")
        if stored:
            target = Path(stored)
        else:
            book_title = job_data.get("bookTitle") or job_data.get("fileName") or ""
            file_name = job_data.get("file_path") or ""
            book_slug = _book_slug(book_title, file_name)
            target = output_dir / book_slug

            # If legacy dir already exists with data, prefer it to avoid breaking older jobs
            if legacy_dir.exists() and any(legacy_dir.iterdir()):
                target = legacy_dir

            job_data["outputDir"] = str(target)
            jobs[job_id] = job_data

    if target is None:
        target = legacy_dir

    if ensure:
        target.mkdir(parents=True, exist_ok=True)

    return target


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
jobs_state_dir = JOBS_DIR
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
_kokoro_support_check = load_kokoro_supports_language()
if _IS_TEST_ENV and _kokoro_support_check is None:
    try:
        from src.tts.kokoro_engine import kokoro_supports_language as _direct_kokoro_support

        _kokoro_support_check = _direct_kokoro_support
    except Exception:
        pass
_COQUI_SUPPORTED = _IS_TEST_ENV or is_coqui_supported_environment()
_PIPER_SUPPORTED = _IS_TEST_ENV or is_piper_supported_environment()
_SPARK_SUPPORTED = _IS_TEST_ENV or is_spark_supported_environment()


def _has_kokoro_support(language: Optional[str]) -> bool:
    if _kokoro_support_check is None:
        return False
    try:
        return bool(_kokoro_support_check(language))
    except Exception:
        return False


def _has_piper_support() -> bool:
    return _PIPER_SUPPORTED


def _has_spark_support() -> bool:
    return _SPARK_SUPPORTED


def _has_coqui_support() -> bool:
    return _COQUI_SUPPORTED


_JOB_WORKERS = max(1, int(os.getenv("JOB_WORKERS", "1") or "1"))  # Processar 1 livro por vez
_job_queue: Optional[asyncio.Queue[str]] = None
_job_workers: list[asyncio.Task] = []
_jobs_in_queue: set[str] = set()
_worker_scale_lock = asyncio.Lock()

_pending_uploads: Dict[str, dict] = {}
_pending_lock = threading.Lock()
_PENDING_TTL_SECONDS = 3600  # 1 hour
_PENDING_META_FILENAME = "upload.json"
_CHAPTER_HEARTBEAT_SECONDS = 20.0  # was 45s — more frequent activity pings
_CHAPTER_TIMEOUT_FACTOR = 2.0  # was 2.5 — less overshoot on estimated duration
_CHAPTER_TIMEOUT_MIN = 60.0  # was 120s — detect stuck chapters faster
# On HF, cap at 120s so slow Edge chapters trigger fallback to Kokoro sooner.
# Locally keep 300s since Edge is faster and there are no local fallbacks.
_CHAPTER_TIMEOUT_MAX = 120.0 if _hf_mode else 300.0
try:
    _CHAPTER_RETRY_MAX = max(0, int(os.getenv("CHAPTER_RETRY_MAX", "6") or "6"))
except (TypeError, ValueError):
    _CHAPTER_RETRY_MAX = 3
# Retry forever was causing infinite loops when ALL engines fail (e.g. on HF
# where fallback engines aren't available). Use a finite retry count instead.
_CHAPTER_RETRY_FOREVER = False
_CHAPTER_RETRY_FOREVER_MAX = max(
    1, int(os.getenv("CHAPTER_RETRY_FOREVER_MAX", "5") or "5")
)  # hard cap even if retry_forever were re-enabled
try:
    _CHAPTER_RETRY_ROUNDS = max(0, int(os.getenv("CHAPTER_RETRY_ROUNDS", "3") or "3"))
except (TypeError, ValueError):
    _CHAPTER_RETRY_ROUNDS = 3  # was 1 — give more rounds before giving up
try:
    _CHAPTER_RETRY_BACKOFF_SECONDS = float(
        os.getenv("CHAPTER_RETRY_BACKOFF_SECONDS", "2.0") or "2.0"
    )
except (TypeError, ValueError):
    _CHAPTER_RETRY_BACKOFF_SECONDS = 2.0
_STALL_THRESHOLD_SECONDS = float(os.getenv("JOB_STALL_THRESHOLD_SECONDS", "300") or "300")
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


_HEALTHCHECK_INTERVAL_SECONDS = _env_float("JOB_HEALTHCHECK_INTERVAL_SECONDS", 15.0)  # was 30s
_HEALTHCHECK_SLOW_EDGE_CPS = _env_float("JOB_HEALTHCHECK_SLOW_EDGE_CPS", EDGE_MIN_CHARS_PER_SECOND)
_HEALTHCHECK_SLOW_CPS = _env_float("JOB_HEALTHCHECK_SLOW_CPS", 30.0)
_HEALTHCHECK_HIGH_CPU = _env_float("JOB_HEALTHCHECK_HIGH_CPU_PERCENT", 85.0)
_HEALTHCHECK_HIGH_MEM = _env_float("JOB_HEALTHCHECK_HIGH_MEM_PERCENT", 85.0)
_HEALTHCHECK_OK_CPU = _env_float("JOB_HEALTHCHECK_OK_CPU_PERCENT", 75.0)
_HEALTHCHECK_OK_MEM = _env_float("JOB_HEALTHCHECK_OK_MEM_PERCENT", 80.0)
_HEALTHCHECK_SLOW_STREAK = max(1, _env_int("JOB_HEALTHCHECK_SLOW_STREAK", 1))  # was 2
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
# Skip chapters larger than this (0 = disabled). Prevents footnote-container files
# that embed the entire book text from blocking conversion for hours.
MAX_CHAPTER_CHARS = _env_int("MAX_CHAPTER_CHARS", 0)


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
                f"This book has {chapter_count} chapters but the current limit is "
                f"{MAX_CHAPTERS_PER_JOB}. Upload smaller excerpts or select fewer chapters."
            ),
        )


def _summarize_resume_job(job_id: str, job_data: dict, saved_at: Optional[str] = None) -> dict:
    return {
        "jobId": job_id,
        "state": job_data.get("state", "queued"),
        "bookTitle": job_data.get("bookTitle", "Unknown Book"),
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


async def _broadcast_chapter_event(job_id: str, chapter_data: dict) -> None:
    """Emit a typed 'chapter_update' SSE event to all SSE clients of job_id."""
    if job_id not in _sse_clients:
        return
    payload = {"_sse_event": "chapter_update", **chapter_data}
    dead_queues = set()
    for queue in _sse_clients[job_id]:
        try:
            queue.put_nowait(payload)
        except (asyncio.QueueFull, Exception):
            dead_queues.add(queue)
    if dead_queues:
        _sse_clients[job_id] -= dead_queues
        if not _sse_clients[job_id]:
            del _sse_clients[job_id]


def _schedule_chapter_broadcast(job_id: Optional[str], chapter_data: Optional[dict]) -> None:
    """Dispatch a per-chapter SSE event from any thread."""
    if not job_id or not chapter_data:
        return
    if job_id not in _sse_clients:
        return
    try:
        loop = asyncio.get_running_loop()
        loop.create_task(_broadcast_chapter_event(job_id, chapter_data))
        return
    except RuntimeError:
        pass
    if _app_loop is None or _app_loop.is_closed():
        return
    _app_loop.call_soon_threadsafe(
        lambda: _app_loop.create_task(_broadcast_chapter_event(job_id, chapter_data))
    )


def _job_status_payload(job_data: dict) -> dict:
    payload = dict(job_data)
    payload["rawLog"] = job_data.get("_raw_log", [])
    payload.pop("_raw_log", None)
    payload["lastActivityAt"] = job_data.get("_lastActivityTs")
    return payload


def _normalize_book_title(value: Optional[str]) -> Optional[str]:
    if not value:
        return None
    cleaned = re.sub(r"[_\-]+", " ", value)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    return cleaned or None


def _safe_file_size(path: Path) -> int:
    try:
        return path.stat().st_size
    except OSError:
        return 0


def _guess_image_mime(suffix: str) -> str:
    lowered = suffix.lower()
    if lowered in {".jpg", ".jpeg"}:
        return "image/jpeg"
    if lowered == ".png":
        return "image/png"
    if lowered == ".webp":
        return "image/webp"
    if lowered == ".gif":
        return "image/gif"
    return "application/octet-stream"


def _find_cover_asset(job_output_dir: Path) -> Optional[Path]:
    preferred_names = [
        "cover.jpg",
        "cover.jpeg",
        "cover.png",
        "cover.webp",
    ]
    for name in preferred_names:
        candidate = job_output_dir / name
        if candidate.exists():
            return candidate

    for suffix in (".jpg", ".jpeg", ".png", ".webp"):
        for candidate in job_output_dir.glob(f"*{suffix}"):
            if candidate.is_file():
                return candidate
    return None


def _locate_job_output_dir_for_recovery(job_id: str) -> Optional[Path]:
    legacy_dir = output_dir / job_id
    if legacy_dir.exists():
        return legacy_dir

    try:
        for streams_dir in output_dir.rglob("streams"):
            if not streams_dir.is_dir():
                continue
            candidate = streams_dir / job_id
            if candidate.exists():
                return streams_dir.parent
    except Exception as exc:
        logger.warning("Failed to scan outputs for job %s: %s", job_id, exc)
    return None


def _restore_job_from_outputs(job_id: str) -> Optional[dict]:
    """Rebuild a finished job if metadata was lost, based on existing outputs."""
    job_output_dir = _locate_job_output_dir_for_recovery(job_id)
    if not job_output_dir or not job_output_dir.exists():
        return None

    mp3_files = sorted(p for p in job_output_dir.glob("*.mp3") if p.is_file())
    zip_files = sorted(p for p in job_output_dir.glob("*.zip") if p.is_file())
    log_path = job_output_dir / "conversion.log"
    has_log = log_path.exists()

    if not mp3_files and not zip_files and not has_log:
        return None

    def _asset_entry(path: Path) -> dict:
        return {
            "name": path.name,
            "url": f"/api/outputs/{job_id}/{path.name}",
            "sizeBytes": _safe_file_size(path),
        }

    outputs: list[dict] = []
    for zip_path in zip_files:
        outputs.append(_asset_entry(zip_path))
    if has_log:
        outputs.append(_asset_entry(log_path))
    for mp3_path in mp3_files:
        outputs.append(_asset_entry(mp3_path))
    outputs = _sort_output_entries(outputs)

    book_title = _normalize_book_title(zip_files[0].stem if zip_files else None)
    if not book_title:
        parent_name = job_output_dir.parent.name if job_output_dir.parent else None
        fallback = _normalize_book_title(parent_name) or _normalize_book_title(job_id)
        book_title = fallback or "Livro Desconhecido"

    chapter_progress = [
        {
            "index": idx,
            "name": path.stem,
            "status": "completed",
            "downloadUrl": f"/api/outputs/{job_id}/{path.name}",
        }
        for idx, path in enumerate(mp3_files)
    ]

    timestamps: list[float] = []
    for path in mp3_files + zip_files:
        with contextlib.suppress(OSError):
            timestamps.append(path.stat().st_mtime)
    if has_log:
        with contextlib.suppress(OSError):
            timestamps.append(log_path.stat().st_mtime)
    completed_ts = max(timestamps) if timestamps else time.time()
    completed_iso = datetime.fromtimestamp(completed_ts, tz=timezone.utc).isoformat()

    cover_entry = None
    cover_path = _find_cover_asset(job_output_dir)
    if cover_path:
        cover_entry = {
            "name": cover_path.name,
            "url": f"/api/outputs/{job_id}/{cover_path.name}",
            "mimeType": _guess_image_mime(cover_path.suffix),
        }

    job_data = {
        "jobId": job_id,
        "state": "finished",
        "events": [
            "♻️ Conversion restored from already saved files",
            "📦 Downloads available - metadata reconstructed automatically",
        ],
        "_raw_log": [],
        "outputs": outputs,
        "outputDir": str(job_output_dir),
        "bookTitle": book_title,
        "bookAuthor": None,
        "engine": job_output_dir.name,
        "voice": None,
        "language": None,
        "progressPercent": 100.0,
        "chaptersCompleted": len(mp3_files),
        "chaptersTotal": len(mp3_files),
        "chapterProgress": chapter_progress,
        "cover": cover_entry,
        "coverUrl": cover_entry["url"] if cover_entry else None,
        "coverMimeType": cover_entry["mimeType"] if cover_entry else None,
        "logUrl": f"/api/outputs/{job_id}/{log_path.name}" if has_log else None,
        "cancelRequested": False,
        "resumeRequested": False,
        "parallelActive": 0,
        "createdAt": completed_iso,
        "startedAt": completed_iso,
        "completedAt": completed_ts,
        "completedAtIso": completed_iso,
        "_lastActivityTs": completed_ts,
        "totalElapsedSeconds": None,
    }
    if cover_entry is None:
        job_data["cover"] = None
    job_data["_raw_log"] = list(job_data["events"])
    return job_data


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
                    _set_job_error(job, str(exc))
                    job["resumeRequested"] = False
                    job["cancelRequested"] = False
                    job["parallelActive"] = 0
                    job["completedAt"] = time.time()
                    _append_event(job, f"❌ Internal failure during conversion: {exc}")
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
            _set_job_error(job, "Source file was lost after server restart")
            _append_event(job, "❌ Temporary source file not found - upload the EPUB again")
            _persist_job(job_id, force=True)
            continue
        job["state"] = "queued"
        job["resumeRequested"] = True
        _append_event(job, "♻️ Conversion resumed after server restart")
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
        # HF Spaces uses shared egress IPs — many Spaces share the same Edge-TTS
        # rate-limit budget. Minimize request count:
        #   - 1 concurrent request (no parallel Edge chunks within a chapter)
        #   - Larger chunks (12K chars) → fewer requests per chapter
        #   - 1 chapter at a time to avoid compounding rate limits
        _set_default("EDGE_MAX_CONCURRENCY", "1")
        _set_default("EDGE_MAX_CONCURRENCY_CAP", "2")
        _set_default("CHAPTER_PARALLEL_COUNT", "1")
        _set_default("CHAPTER_PARALLEL_MAX", "1")
        _set_default("EDGE_CHUNK_CHARS", "12000")  # was 9000 — fewer requests
        _set_default("EDGE_MAX_SEGMENT_SECONDS", "180")
        _set_default("EDGE_ENABLE_PARALLEL", "false")  # force serial chunks
        _set_default("COQUI_MAX_WORKERS", "2")
        _set_default("PIPER_MAX_PROCS", "1")
        # Healthcheck: detect rate-limit slowdowns faster on HF
        _set_default("JOB_HEALTHCHECK_INTERVAL_SECONDS", "10")
        _set_default("JOB_HEALTHCHECK_SLOW_STREAK", "1")
        # Safe mode (fallback when Edge is slow): use very small chunks on HF
        # so each request completes quickly and rate limits clear faster.
        _set_default("EDGE_SAFE_CHUNK_CHARS", "5000")
        _set_default("EDGE_SAFE_MAX_SEGMENT_SECONDS", "120")
        _set_default("EDGE_SAFE_TIMEOUT_MAX", "180")
    elif profile == "cli":
        # Favor throughput on multi-core hosts while keeping caps sane
        edge_cap = max(4, min(8, (hw.cpu_physical or 2) * 2))
        _set_default("EDGE_MAX_CONCURRENCY", str(min(6, edge_cap)))
        _set_default("EDGE_MAX_CONCURRENCY_CAP", str(edge_cap))
        _set_default("CHAPTER_PARALLEL_COUNT", str(min(4, max(2, (hw.cpu_physical or 2) // 2 + 1))))
        _set_default("CHAPTER_PARALLEL_MAX", str(min(6, (hw.cpu_physical or 2) * 2)))
        _set_default("EDGE_CHUNK_CHARS", "11000")
        _set_default("EDGE_MAX_SEGMENT_SECONDS", "300")
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
        _set_default("EDGE_MAX_SEGMENT_SECONDS", "240")
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
_auto_tuner: Optional[AutoTuner] = None  # Will be initialized on startup


# Fallback mock for system_monitor when health_monitor is not available
class _FallbackSystemMonitor:
    """Fallback system monitor for tests or when health_monitor fails to load."""

    def latest(self):
        """Return empty stats."""
        return {}

    def start(self):
        """No-op start."""
        pass

    def stop(self):
        """No-op stop."""
        pass


system_monitor = _FallbackSystemMonitor()  # Will be replaced with real monitor on startup

if FORCE_TURBO:
    desired_workers = max(2, _hardware_profile.cpu_physical or 1)
    if desired_workers > _JOB_WORKERS:
        logger.warning(
            f"Turbo mode: increasing job workers from {_JOB_WORKERS} to {desired_workers}"
        )
        _JOB_WORKERS = desired_workers


async def _hf_keepalive(interval_seconds: float = 600.0) -> None:
    """Ping the local health endpoint periodically to prevent HF Space hibernation.

    HF free-tier Spaces sleep after ~15 min of inactivity. This keeps the
    process alive so users can still download completed conversions hours later.
    Only started when SPACE_ID env var is set (i.e. running on HF Spaces).
    """
    import httpx

    # Use localhost only — pinging the public URL from within the Space causes
    # HF's proxy to count those requests against the rate limit, blocking users.
    # Localhost keeps the Python process and event loop alive without going
    # through HF's proxy.
    port = int(os.getenv("PORT", "7860"))
    url = f"http://localhost:{port}/api/health"
    await asyncio.sleep(60)  # Let the server fully start before first ping
    while True:
        try:
            async with httpx.AsyncClient(timeout=15.0, follow_redirects=True) as client:
                resp = await client.get(url)
                logger.debug("HF keep-alive ping → %s (%s)", resp.status_code, url)
        except Exception as exc:
            logger.debug("HF keep-alive ping failed: %s", exc)
        await asyncio.sleep(interval_seconds)


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

            telemetry_deleted = _cleanup_telemetry_artifacts(
                max_age_hours=TELEMETRY_RETENTION_HOURS
            )
            if telemetry_deleted > 0:
                logger.info("Telemetry cleanup removed %s stale file(s)", telemetry_deleted)

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


def _cleanup_telemetry_artifacts(max_age_hours: int = 720) -> int:
    """Delete stale telemetry artifacts older than retention window."""
    retention_h = max(24, int(max_age_hours or 720))
    cutoff = time.time() - (retention_h * 3600)
    telemetry_dir = CACHE_DIR / "telemetry"
    if not telemetry_dir.exists():
        return 0

    keep_names = {
        "feature-ab-history.json",
        "ci-speed-baseline-nightly.json",
        "benchmark_profiles.json",
        "engine_samples.json",
        "performance-profiles.json",
        "engine-warm-start.json",
    }
    deleted = 0
    for path in telemetry_dir.rglob("*"):
        if not path.is_file():
            continue
        if path.name in keep_names:
            continue
        with contextlib.suppress(OSError):
            if path.stat().st_mtime >= cutoff:
                continue
            path.unlink(missing_ok=True)
            deleted += 1
    return deleted


def _latest_segment_summary(limit_scan: int = 300) -> Optional[Path]:
    """Find newest segment-metrics-summary.json across output tree."""
    candidates: List[Path] = []
    try:
        for idx, path in enumerate(output_dir.rglob("segment-metrics-summary.json")):
            if idx >= max(1, int(limit_scan)):
                break
            if path.is_file():
                candidates.append(path)
    except Exception:
        return None
    if not candidates:
        return None
    try:
        return max(candidates, key=lambda p: p.stat().st_mtime)
    except Exception:
        return candidates[-1]


def _feature_ab_history_path() -> Path:
    """Return canonical path for rolling feature A/B history cache."""
    return CACHE_DIR / "telemetry" / "feature-ab-history.json"


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
    stats = system_monitor.latest() if system_monitor else {}
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
    stage_label = job.get("_lastStage") or job.get("statusHint") or "process"
    inactivity_label = TimeFormatter.format_time(inactivity_seconds)
    attempts = job.get("_stallRestartCount", 0)
    job["_run_token"] = str(uuid.uuid4())
    message_prefix = f"⚠️ No progress for {inactivity_label} (stage: {stage_label}). "
    if attempts < _STALL_MAX_AUTO_RETRIES:
        job["_stallRestartCount"] = attempts + 1
        job["state"] = "queued"
        job["resumeRequested"] = True
        job["cancelRequested"] = False
        job["statusHint"] = "Restarting after stall detection"
        _append_event(
            job,
            f"{message_prefix}Retrying automatically "
            f"({job['_stallRestartCount']}/{_STALL_MAX_AUTO_RETRIES}).",
        )
        _persist_job(job_id, force=True)
        if not _enqueue_job(job_id):
            return True
        return False

    job["state"] = "interrupted"
    job["resumeRequested"] = False
    job["cancelRequested"] = False
    job["statusHint"] = "Conversion interrupted (no progress)"
    _set_job_error(
        job,
        "Conversion automatically interrupted after repeated failures. "
        "Retry the job or choose another voice engine.",
    )
    job["completedAt"] = now
    _append_event(
        job,
        f"{message_prefix}Stopped to avoid a permanent stall. "
        "Try again with different settings.",
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

            stats = system_monitor.latest() if system_monitor else {}
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
                    "Conversion interrupted (server restarted and temporary source file was lost)"
                )
                job_data["events"] = job_data.get("events", []) + [
                    "",
                    "⚠️ Conversion interrupted due to server restart",
                    "❌ Source file was lost - resume is not possible",
                    "ℹ️ To avoid this, wait for conversion to finish before leaving",
                ]
                job_manager.save_job(job_id, job_data)
                logger.warning(f"Job {job_id} marked as interrupted (source file lost)")

tts_factory = TTSFactory()
telemetry = TelemetryRecorder()
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
        fallback_candidates = []
        if _has_coqui_support():
            fallback_candidates.append("coqui")
        fallback_candidates.append("kokoro")
        if _has_spark_support():
            fallback_candidates.append("spark")
        if _has_piper_support():
            fallback_candidates.append("piper")
        fallback_engines = _rank_fallbacks(fallback_candidates)
        for engine_name in fallback_engines:
            if engine_name == "kokoro" and not _has_kokoro_support(config.primary_language):
                continue
            if engine_name == "piper" and not _has_piper_support():
                continue
            if engine_name == "spark" and not _has_spark_support():
                continue
            if engine_name == "coqui" and not _has_coqui_support():
                continue
            clone = _clone_config_for_engine(config, engine_name)
            if clone.engine.lower() == "edge":
                clone.edge_aggressive_mode = True
            chain.append(clone)
    return chain


def _prepare_auto_engine_pool(config: ConversionConfig) -> dict[str, ConversionConfig]:
    pool: dict[str, ConversionConfig] = {}
    # Priority: edge (fast cloud), coqui (quality), kokoro (fast local), spark (LLM-based)
    # Piper excluded from auto due to lower quality
    candidate_order = ["edge"]
    if _has_coqui_support():
        candidate_order.append("coqui")
    candidate_order.append("kokoro")
    if _has_spark_support():
        candidate_order.append("spark")
    for name in candidate_order:
        if name == "kokoro" and not _has_kokoro_support(config.primary_language):
            continue
        if name == "coqui" and not _has_coqui_support():
            continue
        if name == "spark" and not _has_spark_support():
            continue
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
        edge_cfg.edge_max_segment_seconds = max(45, min(edge_cfg.edge_max_segment_seconds, 600))
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

    # Order from fastest to slowest: edge > coqui
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
    fromChapterToEnd: Optional[str] = Form(None),
    fromChapterToChapter: Optional[str] = Form(None),
    footnote_mode: Optional[str] = Form("inline"),
    language: Optional[str] = Form(None),
    priority: Optional[str] = Form(None),
    formatting_cues: Optional[str] = Form("on"),
    no_parallel: Optional[str] = Form(None),
    parallel_slots: Optional[str] = Form(None),
    max_performance: Optional[str] = Form(None),
    chapter_stall_seconds: Optional[str] = Form(None),
    edge_network_tier: Optional[str] = Form(None),
    edge_chunk_chars: Optional[str] = Form(None),
    edge_max_segment_seconds: Optional[str] = Form(None),
    edge_enable_parallel: Optional[str] = Form(None),
    edge_auto_tune: Optional[str] = Form(None),
    edge_stable_mode: Optional[str] = Form(None),
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
    chapter_stall_override = _parse_form_float(
        chapter_stall_seconds,
        min_value=10.0,
        max_value=900.0,
    )
    edge_network_tier_override = None
    if edge_network_tier:
        normalized = edge_network_tier.strip().lower()
        if normalized in {"slow", "medium", "fast", "ultra"}:
            edge_network_tier_override = normalized
    edge_chunk_override = _parse_form_int(edge_chunk_chars, min_value=4000, max_value=24000)
    edge_segment_override = _parse_form_int(edge_max_segment_seconds, min_value=30, max_value=600)
    edge_parallel_override = _parse_form_optional_bool(edge_enable_parallel)
    edge_auto_tune_override = _parse_form_optional_bool(edge_auto_tune)
    edge_stable_mode_flag = _parse_form_optional_bool(edge_stable_mode)
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
    from_chapter_to_end = (fromChapterToEnd or "").strip() or None
    from_chapter_to_chapter = (fromChapterToChapter or "").strip() or None
    if from_chapter_to_end and from_chapter_to_chapter:
        raise HTTPException(
            status_code=400,
            detail="Use apenas fromChapterToEnd ou fromChapterToChapter.",
        )
    if from_chapter_to_chapter:
        parsed_range = ConverterApplication._parse_range_selector(from_chapter_to_chapter)
        if not parsed_range:
            raise HTTPException(
                status_code=400,
                detail="Invalid range. Use A..B (e.g. 5.1..7.3).",
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
                raise HTTPException(status_code=404, detail="Upload not found or expired")
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
            raise HTTPException(status_code=400, detail="No file uploaded")
        job_id = f"{uuid.uuid4()}"
        job_input_dir = job_inputs_dir / job_id
        job_input_dir.mkdir(parents=True, exist_ok=True)
        temp_file = job_input_dir / Path(file.filename or "ebook.epub").name
        raw_payload = await file.read()
        if MAX_UPLOAD_BYTES and len(raw_payload) > MAX_UPLOAD_BYTES:
            raise HTTPException(
                status_code=413,
                detail=f"File exceeds the {MAX_UPLOAD_MB} MB limit",
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
    book_slug = _book_slug(book_title, temp_file.name)
    output_book_dir = output_dir / book_slug
    output_book_dir.mkdir(parents=True, exist_ok=True)
    cache_base = CACHE_DIR / book_slug
    cache_base.mkdir(parents=True, exist_ok=True)

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
        "fromChapterToEnd": from_chapter_to_end,
        "fromChapterToChapter": from_chapter_to_chapter,
        "footnote_mode": footnote_mode,
        "language": language,
        "priority": priority,
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
        "maxPerformance": max_performance_enabled,
        "chapterStallSeconds": chapter_stall_override,
        "edgeNetworkTier": edge_network_tier_override,
        "edgeChunkChars": edge_chunk_override,
        "edgeMaxSegmentSeconds": edge_segment_override,
        "edgeEnableParallel": edge_parallel_override,
        "edgeAutoTune": edge_auto_tune_override,
        "edgeStableMode": edge_stable_mode_flag,
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
    _append_event(jobs[job_id], "📚 File received, waiting for processing...")

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
        _finalize_cancel(job_id, job, "🛑 Conversion cancelled before start")
        return {"status": "cancelled"}

    if state != "cancelling":
        job["state"] = "cancelling"
        _append_event(job, "🛑 Cancellation requested. Finishing current chapter...")
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
        raise HTTPException(status_code=409, detail="Source file is no longer available")
    job["cancelRequested"] = False
    job.pop("_purgeRequested", None)
    job["resumeRequested"] = True
    job["state"] = "queued"
    _append_event(job, "♻️ Resuming conversion at user request")
    _persist_job(job_id, force=True)
    if not _enqueue_job(job_id):
        raise HTTPException(status_code=503, detail="Processing queue is currently unavailable")
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
            _finalize_cancel(job_id, job, "🗑️ Conversion removed before start")
            return {"status": "deleted"}
        if state != "cancelling":
            job["state"] = "cancelling"
            _append_event(job, "🗑️ Removal requested. Finishing current chapter...")
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


@app.get("/api/jobs/{job_id}/fulltext")
async def get_job_fulltext(job_id: str) -> dict:
    """Return full text of all chapters before audio conversion starts.

    This allows the UI to display chapter text immediately, even before
    any audio segments are ready.
    """
    job_data = jobs.get(job_id) or job_manager.load_job(job_id)
    if not job_data:
        raise HTTPException(status_code=404, detail="Job not found")

    # Get the source file path
    input_file = job_data.get("inputFile")
    if not input_file or not Path(input_file).exists():
        raise HTTPException(status_code=404, detail="Source file not found")

    try:
        # Read the ebook and extract chapter structure
        reader = EbookReader(input_file)
        book_chapters = reader.get_chapter_structure(preserve_all=True)

        # Build response with chapter text
        chapters = []
        for idx, chapter in enumerate(book_chapters):
            chapter_text = getattr(chapter, "speech_text", None) or chapter.text or ""
            clean_text = TextFormattingProcessor.strip_inline_markdown(chapter_text)

            chapters.append(
                {
                    "index": idx,
                    "name": chapter.name or f"Chapter {idx}",
                    "text": clean_text,
                    "charCount": len(clean_text),
                }
            )

        return {
            "jobId": job_id,
            "bookTitle": job_data.get("bookTitle", ""),
            "bookAuthor": job_data.get("bookAuthor", ""),
            "chapters": chapters,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to extract text: {str(e)}")


@app.post("/api/cleanup")
async def cleanup_old_files(max_age_hours: int = 48) -> dict:
    """
    Cleanup old files from local storage.

    This endpoint should be called periodically (e.g., via cron job).
    """
    result = {"local_deleted": 0, "errors": []}

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

    # Cleanup old job state files
    jobs_deleted = job_manager.cleanup_old_jobs(max_age_hours=max_age_hours)
    result["jobs_deleted"] = jobs_deleted
    result["telemetry_deleted"] = _cleanup_telemetry_artifacts(
        max_age_hours=max(max_age_hours, TELEMETRY_RETENTION_HOURS)
    )

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
    print(f"\n{'=' * 60}")
    print("🔄 RESTART SOLICITADO")
    print(f"   Manter cache: {keep_cache}")
    print(f"   Keep completed: {keep_finished}")
    print(f"{'=' * 60}")
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
    print(f"   ✓ {purged} job(s) removed")
    if not keep_finished:
        print("🗑️  Limpando outputs...")
        _clear_all_outputs(preserve_cache=keep_cache)
        print("   ✓ Outputs limpos")
    if not keep_cache:
        print("🗑️  Limpando cache...")
        _clear_all_caches()
        print("   ✓ Cache limpo")
    print(f"{'=' * 60}")
    print("✅ CLEANUP COMPLETE — Restarting server...")
    print(f"{'=' * 60}\n")
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
    Returns detailed health monitor statistics.
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
    Returns auto-recovery system statistics.
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

    # Attempt to rebuild metadata from the existing outputs on disk
    recovered_job = _restore_job_from_outputs(job_id)
    if recovered_job:
        jobs[job_id] = recovered_job
        if job_manager.save_job(job_id, recovered_job):
            saved_at = _determine_saved_at(recovered_job)
            book_title = recovered_job.get("bookTitle") or "Unknown"
            _recent_jobs_index[job_id] = (saved_at, book_title)
            logger.warning("Job %s rehydrated from outputs directory", job_id)
        else:
            logger.error("Failed to persist reconstructed job %s", job_id)
        _schedule_job_broadcast(job_id, recovered_job)
        return JobStatus(**_job_status_payload(recovered_job))

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
                    sse_event = job_data.get("_sse_event")
                    if sse_event:
                        clean = {k: v for k, v in job_data.items() if k != "_sse_event"}
                        yield f"event: {sse_event}\ndata: {json.dumps(clean)}\n\n"
                    else:
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
        raise HTTPException(status_code=404, detail="File not found")
    return FileResponse(str(path))


@app.post("/api/uploads")
async def upload_ebook(file: UploadFile = File(...)) -> dict:
    """Upload ebook ahead of conversion to extract metadata/cover."""
    if file is None:
        raise HTTPException(status_code=400, detail="No file uploaded")

    raw_payload = await file.read()
    if MAX_UPLOAD_BYTES and len(raw_payload) > MAX_UPLOAD_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"File exceeds the {MAX_UPLOAD_MB} MB limit",
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
    book_author = "Unknown Author"
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


@app.get("/api/estimate")
async def estimate_conversion(
    upload_id: str,
    engine: str = "auto",
) -> dict:
    """Estimate conversion time and output size for an uploaded ebook.

    Returns per-engine estimates using observed telemetry throughput,
    falling back to conservative defaults when no samples are available.

    Args:
        upload_id: ID returned by POST /api/uploads
        engine:    TTS engine to estimate for. "auto" returns all engines.

    Response:
        chapters        Total chapters found
        total_chars     Total characters to synthesise
        engine          Engine the primary estimate applies to
        chars_per_second  Throughput used for the estimate (chars/s)
        telemetry_based  True if throughput came from real samples
        estimated_duration_seconds
        estimated_duration_formatted  Human-readable (e.g. "12 min 34 s")
        estimated_output_mb  Approximate MP3 size at 128 kbps
        engine_estimates  Dict of engine → estimate for all engines
    """
    # ── Locate the uploaded file ─────────────────────────────────────────
    with _pending_lock:
        upload_info = _pending_uploads.get(upload_id)

    file_path: Optional[str] = None
    if upload_info:
        file_path = upload_info.get("file_path")
    else:
        # Try to find it on disk (upload may have been consumed by convert)
        upload_dir = uploads_dir / upload_id
        if upload_dir.exists():
            for candidate in upload_dir.iterdir():
                if candidate.suffix.lower() in {".epub", ".pdf"}:
                    file_path = str(candidate)
                    break

    if not file_path or not Path(file_path).exists():
        raise HTTPException(status_code=404, detail="Upload not found or already consumed")

    # ── Count chapters and chars (use cache when pre-warmed by upload) ───
    total_chars = 0
    chapter_count = 0
    chapter_breakdown: list[dict] = []

    try:
        cache_manager = get_cache_manager()
        cached = cache_manager.get_cached_chapters(Path(file_path))
        if cached and cached.get("chapters"):
            chapters_data = cached["chapters"]
            for ch in chapters_data:
                text = ch.get("text", "")
                chars = len(text)
                chapter_breakdown.append({"name": ch.get("title", ""), "chars": chars})
                total_chars += chars
            chapter_count = len(chapters_data)
        else:
            reader = EbookReader(file_path)
            for ch in reader.get_chapters():
                text = getattr(ch, "text", "") or ""
                chars = len(text)
                chapter_breakdown.append({"name": getattr(ch, "name", ""), "chars": chars})
                total_chars += chars
            chapter_count = len(chapter_breakdown)
    except Exception as exc:
        raise HTTPException(status_code=422, detail=f"Failed to parse ebook: {exc}")

    if chapter_count == 0:
        raise HTTPException(status_code=422, detail="No chapters found in ebook")

    # ── Default throughput per engine (chars/s, conservative) ────────────
    _DEFAULTS: dict[str, float] = {
        "edge": 110.0,
        "kokoro": 35.0,
        "piper": 25.0,
        "coqui": 20.0,
        "auto": 110.0,
    }
    # 128 kbps MP3: 16 KB/s
    _KBPS_BYTES_PER_SECOND = 128 * 1024 / 8

    telem_summary = telemetry.summary()

    def _estimate_for_engine(eng: str) -> dict:
        telem = telem_summary.get(eng, {})
        if telem and telem.get("avg_chars_per_second", 0) > 0:
            cps = float(telem["avg_chars_per_second"])
            telem_based = True
            samples = int(telem.get("samples", 0))
        else:
            cps = _DEFAULTS.get(eng, _DEFAULTS["edge"])
            telem_based = False
            samples = 0

        est_seconds = total_chars / cps if cps > 0 else 0.0
        est_mb = (est_seconds * _KBPS_BYTES_PER_SECOND) / (1024 * 1024)

        mins, secs = divmod(int(est_seconds), 60)
        hours, mins = divmod(mins, 60)
        if hours:
            formatted = f"{hours}h {mins}m {secs}s"
        elif mins:
            formatted = f"{mins}m {secs}s"
        else:
            formatted = f"{secs}s"

        result: dict = {
            "chars_per_second": round(cps, 1),
            "telemetry_based": telem_based,
            "telemetry_samples": samples,
            "estimated_duration_seconds": round(est_seconds),
            "estimated_duration_formatted": formatted,
            "estimated_output_mb": round(est_mb, 1),
        }
        return result

    known_engines = list(_DEFAULTS.keys() - {"auto"})
    engine_estimates = {eng: _estimate_for_engine(eng) for eng in known_engines}

    # "auto" picks the best engine with telemetry data, else edge
    ranked = telemetry.ranked_engines()
    primary_engine = ranked[0] if ranked else "edge"
    if engine != "auto" and engine in _DEFAULTS:
        primary_engine = engine

    primary = _estimate_for_engine(primary_engine)

    return {
        "chapters": chapter_count,
        "total_chars": total_chars,
        "engine": primary_engine,
        "chars_per_second": primary["chars_per_second"],
        "telemetry_based": primary["telemetry_based"],
        "telemetry_samples": primary["telemetry_samples"],
        "estimated_duration_seconds": primary["estimated_duration_seconds"],
        "estimated_duration_formatted": primary["estimated_duration_formatted"],
        "estimated_output_mb": primary["estimated_output_mb"],
        "engine_estimates": engine_estimates,
        "chapter_breakdown": chapter_breakdown,
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


@app.get("/api/telemetry/segments")
async def get_segment_telemetry() -> dict:
    """Return latest segment-level telemetry summary if available."""
    summary_path = _latest_segment_summary()
    if summary_path is None:
        return {"available": False, "summary": None, "source": None}
    try:
        payload = json.loads(summary_path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Failed to read segment telemetry: {exc}")
    return {
        "available": True,
        "summary": payload if isinstance(payload, dict) else {},
        "source": str(summary_path),
    }


@app.get("/api/telemetry/feature-history")
async def get_feature_ab_history(limit: int = 20) -> dict:
    """Return rolling feature A/B benchmark history, when available."""
    history_path = _feature_ab_history_path()
    if not history_path.exists():
        return {
            "available": False,
            "history": {"entries": []},
            "entries": [],
            "count": 0,
            "source": str(history_path),
        }
    try:
        payload = json.loads(history_path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Failed to read feature history: {exc}")

    history = payload if isinstance(payload, dict) else {"entries": []}
    entries = history.get("entries", [])
    if not isinstance(entries, list):
        entries = []
    entries = [item for item in entries if isinstance(item, dict)]
    safe_limit = max(1, min(200, int(limit or 20)))
    return {
        "available": True,
        "history": history,
        "entries": entries[:safe_limit],
        "count": len(entries),
        "source": str(history_path),
    }


@app.get("/api/sessions")
async def get_sessions(last: int = 0) -> dict:
    """Return conversion session history from the persistent log.

    Query params:
        last (int): Return only the last N sessions (0 = all, default).

    Returns a list of session records, newest last, plus aggregate stats.
    """
    from src.session_logger import read_sessions

    safe_last = max(0, min(1000, int(last or 0)))
    records = read_sessions(last_n=safe_last)

    # Aggregate stats across returned records
    total = len(records)
    outcomes: dict[str, int] = {}
    engines: dict[str, int] = {}
    modes: dict[str, int] = {}
    total_duration = 0.0
    total_chapters = 0

    for r in records:
        outcomes[r.get("outcome", "unknown")] = outcomes.get(r.get("outcome", "unknown"), 0) + 1
        eng = r.get("engine", "")
        if eng:
            engines[eng] = engines.get(eng, 0) + 1
        mode = r.get("mode", "")
        if mode:
            modes[mode] = modes.get(mode, 0) + 1
        total_duration += r.get("duration_seconds", 0.0) or 0.0
        total_chapters += r.get("chapters_converted", 0) or 0

    return {
        "sessions": records,
        "count": total,
        "stats": {
            "outcomes": outcomes,
            "engines": engines,
            "modes": modes,
            "total_duration_seconds": round(total_duration, 1),
            "total_chapters_converted": total_chapters,
        },
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


def _purge_job_data(job_id: str, job: Optional[dict] = None, *, purge_cache: bool = True) -> None:
    """Remove all persisted data and artifacts for a job."""
    _remove_job_from_queue(job_id)
    if job:
        if purge_cache:
            _clear_job_cache(job)
        _cleanup_job_inputs(job)
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
    _append_event(job, "🛑 Conversion cancelled by user")
    job["state"] = "cancelled"
    _set_job_error(job, "Cancelled by user")
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
            _finalize_cancel(job_id, job, note or "🛑 Conversion cancelled before start")
            return True
        if job.get("_run_token") != run_token:
            _append_event(job, "⏹️ Current run replaced by a newer attempt.")
            return True
        return False

    try:
        if _should_abort_current_run("🛑 Conversion cancelled before start"):
            return

        job["state"] = "running"
        job["statusHint"] = "Preparing conversion..."

        # Reset adaptive Edge TTS settings for new conversion
        reset_adaptive_settings()

        _append_event(job, "📚 EBOOK METADATA")
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
        edge_stable_mode = job.get("edgeStableMode")
        chapter_stall_seconds = job.get("chapterStallSeconds")
        edge_network_tier = job.get("edgeNetworkTier")
        coqui_chunk_override = job.get("coquiChunkChars")
        coqui_workers_override = job.get("coquiMaxWorkers")
        coqui_safe_override = job.get("coquiSafeMode")
        piper_procs_override = job.get("piperMaxProcs")

        if max_performance:
            if edge_chunk_override is None:
                edge_chunk_override = 24000
            if edge_segment_override is None:
                edge_segment_override = 300
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

        if edge_stable_mode:
            if edge_chunk_override is None:
                edge_chunk_override = 4000
            if edge_segment_override is None:
                edge_segment_override = 120
            edge_parallel_override = False
            if edge_auto_tune_override is None:
                edge_auto_tune_override = False
            if chapter_stall_seconds is None:
                chapter_stall_seconds = 60.0
            if not edge_network_tier:
                edge_network_tier = "slow"

        if chapter_stall_seconds is not None:
            os.environ["CHAPTER_STALL_SECONDS"] = str(chapter_stall_seconds)
        if edge_network_tier:
            os.environ["EDGE_NETWORK_TIER"] = str(edge_network_tier)

        if clear_cache_flag:
            _append_event(job, "🗑️ Clearing book cache before starting...")
            _clear_job_cache(job)
        _append_event(job, "📖 Analyzing ebook structure...")

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

        title = reader.title or "Unknown_Book"
        author = reader.author or "Unknown Author"
        job["bookTitle"] = title
        job["bookAuthor"] = author

        _append_event(job, f"📜 Title: {title}")
        _append_event(job, f"✍️ Author: {author}")
        job["chaptersCompleted"] = 0
        verbose_enabled = True if verbose_flag is None else bool(verbose_flag)

        # Prepare chapters first to analyze language
        _append_event(job, "📑 Extracting chapters from the book...")
        _update_job_activity(job, stage="chapter_extraction")
        converter_app = ConverterApplication()
        converter_app._interactive_mode = False
        try:
            structure_items = converter_app._generate_structure_items(reader)
        except Exception:
            structure_items = []
        selector_text = " ".join(
            part for part in (job.get("chapters"), job.get("sections")) if part
        )
        range_start = job.get("fromChapterToEnd")
        range_span = job.get("fromChapterToChapter")
        available_preview = ", ".join(str(item.index) for item in structure_items[:10])

        if structure_items:
            range_end = None
            if range_span:
                parsed_range = converter_app._parse_range_selector(range_span)
                if parsed_range:
                    range_start, range_end = parsed_range
                else:
                    range_start = None
            if range_start:
                structure_items, filtered = converter_app._filter_structure_range(
                    structure_items, range_start, range_end
                )
                if filtered and not structure_items:
                    selector_label = range_span or range_start
                    message = converter_app.localization.t(
                        "selectors_not_found",
                        selectors=selector_label,
                        available=available_preview,
                    )
                    _append_event(job, f"❌ {message}")
                    raise RuntimeError(message)

            selectors: list[str] = []
            if job.get("chapters"):
                selectors.extend(converter_app._expand_selector_args([job.get("chapters")]))
            if job.get("sections"):
                selectors.extend(converter_app._expand_selector_args([job.get("sections")]))
            if selectors:
                structure_items, filtered = converter_app._filter_structure_selection(
                    structure_items, selectors
                )
                if filtered and not structure_items:
                    selector_preview = ", ".join(selectors)
                    message = converter_app.localization.t(
                        "selectors_not_found",
                        selectors=selector_preview,
                        available=available_preview,
                    )
                    _append_event(job, f"❌ {message}")
                    raise RuntimeError(message)

        # Detect language from book content
        _append_event(job, "")
        _append_event(job, "🌐 LANGUAGE DETECTION")
        _append_event(job, "-" * 64)

        language_profile: Optional[LanguageProfile] = None
        detected_lang = None
        job_language = job.get("language")
        if job_language and job_language.lower() not in ("auto", ""):
            detected_lang = job_language
            language_profile = LanguageProfile(
                primary=detected_lang,
                languages=[detected_lang],
                predictions=[],
                analysed_chars=0,
            )
            _append_event(job, f"🌐 User-selected language: {detected_lang}")
        elif structure_items:
            _append_event(job, "🔍 Analyzing content to detect language...")
            try:
                language_profile = converter_app._prepare_language_profile(
                    reader, structure_items, verbose=verbose_enabled
                )
            except Exception as exc:
                _append_event(job, f"⚠️ Language detection error: {exc}")
                language_profile = None
            if language_profile and language_profile.primary:
                detected_lang = language_profile.primary
                if language_profile.predictions:
                    confidence = language_profile.predictions[0].probability
                    _append_event(
                        job,
                        f"🌐 Detected language: {detected_lang} (confidence: {confidence:.1%})",
                    )
                else:
                    _append_event(job, f"🌐 Detected language: {detected_lang}")
            else:
                detected_lang = "pt-BR"
                _append_event(job, f"🌐 Using default language: {detected_lang}")
                language_profile = LanguageProfile(
                    primary=detected_lang,
                    languages=[detected_lang],
                    predictions=[],
                    analysed_chars=0,
                )
        else:
            detected_lang = "pt-BR"
            _append_event(job, f"🌐 Not enough text for detection, using: {detected_lang}")
            language_profile = LanguageProfile(
                primary=detected_lang,
                languages=[detected_lang],
                predictions=[],
                analysed_chars=0,
            )

        converter_app.language_profile = language_profile
        job["detectedLanguage"] = detected_lang
        _persist_job(job_id, force=True)  # Persist metadata
        _update_job_activity(job, stage="language_detected")

        # Create log callback to capture verbose TTS engine output
        def tts_log_callback(message: str) -> None:
            """Capture verbose TTS output and add to raw log + statusHint."""
            raw_log = job.setdefault("_raw_log", [])
            raw_log.append(message)
            # Show important status messages in UI (model loading, tuning, retry)
            status_keywords = [
                # Loading/downloading
                "carregando",
                "baixando",
                "modelo",
                "loading",
                "download",
                "ready",
                "ready",
                # Tuning and retry
                "tuning",
                "ajust",
                "chunk",
                "retry",
                "tentando",
                "rate limit",
                "aguardando",
                "backoff",
                "dividindo",
                "recuper",
                "segment",
                "reduz",
                "otimiz",
                # Warmup and config
                "warmup",
                "config",
                "parallel",
                "concurr",
            ]
            if any(kw in message.lower() for kw in status_keywords):
                job["statusHint"] = message
                # Also append to events for visibility
                _append_event(job, f"🔧 {message}")

        # Resolve per-book/per-engine roots
        book_slug = _book_slug(job.get("bookTitle"), job.get("file_path"))
        output_root = Path(job.get("outputDir") or (output_dir / book_slug))
        cache_root = Path(job.get("cacheDir") or (CACHE_DIR / book_slug))

        # Create TTS engine using factory with optimized compression
        model_path = Path(job.get("model")) if job.get("model") else None
        # Treat "auto" as "edge" (auto mode removed - edge is now default)
        requested_engine = job.get("engine", "edge")
        if (requested_engine or "").lower() == "auto":
            requested_engine = "edge"
        priority_selectors = (
            converter_app._expand_selector_args([job.get("priority")])
            if job.get("priority")
            else []
        )
        config = ConversionConfig(
            engine=requested_engine,
            job_id=job_id,
            voice=job.get("voice"),
            model_path=model_path,
            primary_language=detected_lang or "auto",
            output_dir=str(output_root),
            cache_dir=str(cache_root),
            preserve_all_chapters=not filter_chapters_flag,
            # Optimized compression for web delivery (reduce file size & bandwidth)
            bitrate=job.get("bitrate") or "8k",  # 8 kbps - good quality for voice, ~3.6 MB/hour
            sample_rate=job.get("sampleRate") or 16_000,  # 16 kHz - sufficient for speech
            channels=job.get("channels") or 1,  # Mono - audiobooks don't need stereo
            force_reprocess=bool(job.get("forceReprocess")),
            clear_cache=clear_cache_flag,
            footnote_mode=job.get("footnote_mode") or "inline",
            footnote_context_words=converter_app.FOOTNOTE_CONTEXT_WORDS,
            priority_selectors=priority_selectors,
            speak_formatting_cues=job.get("formattingCues", True),
            formatting_locale=_normalize_locale(job.get("uiLanguage"), "pt"),
            coqui_chunk_chars=coqui_chunk_override,
            coqui_max_workers=coqui_workers_override,
            coqui_safe_mode=coqui_safe_override,
            piper_max_procs=piper_procs_override,
            verbose=verbose_enabled,  # Enable verbose logging for terminal-like output
            log_callback=tts_log_callback,  # Capture all verbose logs
        )
        config.use_language_detection = (
            True if use_language_detection_flag is None else bool(use_language_detection_flag)
        )
        config.prioritize_primary_language = (
            True if prioritize_primary_flag is None else bool(prioritize_primary_flag)
        )
        if edge_auto_tune_override is not None:
            config.edge_auto_tune = bool(edge_auto_tune_override)
        if edge_stable_mode is not None:
            config.extra["edge_stable_mode"] = "1" if edge_stable_mode else "0"
        config.extra.setdefault("voice_auto", "1" if job.get("voice") is None else "0")
        converter_app._apply_language_preferences(config)

        chapters = list(reader.get_chapters())
        if structure_items:
            structure_items = converter_app._apply_text_transforms(structure_items, config, reader)
            converter_app._apply_structure_to_reader(reader, structure_items)
            chapters = (
                reader.get_chapter_structure(preserve_all=config.preserve_all_chapters)
                or reader.get_chapters()
            )
        if config.priority_selectors:
            chapters = _apply_priority_order(chapters, config.priority_selectors)
        _append_event(job, f"✅ {len(chapters)} chapters found")
        _update_job_activity(job, stage="chapters_ready")
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
        force_sequential = bool(job.get("noParallel")) or edge_stable_mode
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
            _append_event(job, f"🧹 Duplicate chapter detected: {duplicates_removed} removed")

        # Validate chapter count against TOC
        expected_count = getattr(reader, "_toc_expected_chapters", 0)
        if expected_count > 0 and len(chapters) != expected_count and duplicates_removed > 0:
            if len(chapters) + duplicates_removed == expected_count:
                _append_event(
                    job,
                    f"⚠️  VALIDATION: TOC reports {expected_count} chapters, but detected {len(chapters)}",
                )
                _append_event(
                    job,
                    f"🔄 Auto-fix: restoring {duplicates_removed} removed chapter(s)",
                )
                chapters = original_chapters
        try:
            _enforce_chapter_limit(len(chapters))
        except HTTPException as limit_error:
            _append_event(job, f"❌ {limit_error.detail}")
            _persist_job(job_id, force=True)
            raise
        selection_note = " (filter applied)" if selector_text else ""
        _append_event(job, f"📊 Chapters: {len(chapters)}{selection_note}")
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

        # Detect size outliers (chapters >5× median) and warn before conversion starts.
        if chapter_char_totals:
            sorted_lengths = sorted(chapter_char_totals.values())
            median_chars = sorted_lengths[len(sorted_lengths) // 2]
            outlier_floor = 50_000
            outlier_threshold = max(median_chars * 5, outlier_floor)
            for idx, ch_chars in chapter_char_totals.items():
                if ch_chars > outlier_threshold and ch_chars > outlier_floor:
                    ch = chapters[idx - 1] if 0 < idx <= len(chapters) else None
                    ch_name = getattr(ch, "name", f"Chapter {idx}")[:60] if ch else f"Chapter {idx}"
                    ratio = ch_chars // max(median_chars, 1)
                    suggested = (ch_chars // 1000) * 1000
                    _append_event(
                        job,
                        f"⚠️ Oversized chapter [{idx}]: {ch_name}"
                        f" ({ch_chars:,} chars = {ratio}× median)"
                        f" → Set MAX_CHAPTER_CHARS={suggested:,} to skip it",
                    )

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
            _append_event(job, f"🔧 Initializing TTS engine ({config.engine})...")
            while engine_index < len(engine_chain):
                candidate = engine_chain[engine_index]
                engine_name = (candidate.engine or "").lower()
                _set_engine_status(job, engine_name, "loading", "Loading model...")
                try:
                    engine_obj = tts_factory.create_engine(candidate)
                    active_config = candidate
                    if engine_name:
                        engine_seeds[engine_name] = engine_obj
                    _set_engine_status(job, engine_name, "ready", "Ready")
                    _append_event(job, f"✅ Engine {candidate.engine} ready")
                    break
                except ImportError as exc:
                    _set_engine_status(job, engine_name, "error", str(exc))
                    _append_event(job, f"⚠️ Engine unavailable: {exc}")
                except Exception as exc:
                    _set_engine_status(job, engine_name, "error", str(exc))
                    _append_event(job, f"⚠️ Failed to initialize engine '{candidate.engine}': {exc}")
                engine_index += 1

            if not engine_seeds or active_config is None:
                job["state"] = "failed"
                _set_job_error(job, "No TTS engine available")
                _append_event(job, "❌ No TTS engine available to start conversion")
                _persist_job(job_id, force=True)
                return
        else:
            active_config = config
            auto_engine_pool = _prepare_auto_engine_pool(config)
            if not auto_engine_pool:
                job["state"] = "failed"
                _set_job_error(job, "No engine available in automatic mode")
                _append_event(job, "❌ No engine available in automatic mode")
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
        _append_event(job, f"🗣️ Voz: {active_config.voice or 'default'}")
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
                    f"⚖️ {active_jobs} active conversions → adjusting parallelism {parallel_slots}→{balanced_slots}",
                )
                parallel_slots = balanced_slots
        job["parallelSlots"] = parallel_slots
        if force_sequential:
            _append_event(job, "🔒 Parallelism disabled (one chapter at a time)")
        elif edge_auto_tune and parallel_slots_cap:
            _append_event(
                job,
                f"🌐 Edge auto-ajuste: limite {parallel_slots_cap} chapter(s) in parallel ({edge_network_tier})",
            )
        elif parallel_slots > 1:
            _append_event(
                job, f"🚀 Automatic parallel: up to {parallel_slots} simultaneous chapters"
            )
        else:
            _append_event(job, "🔄 Sequential mode: one chapter at a time")

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
            _append_event(
                job, "♻️ Resuming previous conversion - keeping already generated chapters"
            )

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
                _append_event(job, f"⏩ {len(existing_outputs)} chapter(s) were already converted")
                job["chaptersCompleted"] = len(completed_indices)
                for completed_idx in completed_indices:
                    _complete_chapter_progress(completed_idx, broadcast=False)
                _update_job_progress(force_broadcast=True)

        if _should_abort_current_run("🛑 Conversion cancelled after processing chapters"):
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
                _append_event(job, "🖼️ Cover reused from cache")
                _persist_job(job_id, force=True)
            except Exception as cover_exc:
                _append_event(job, f"⚠️ Failed to reuse cover: {cover_exc}")
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
                _append_event(job, "🖼️ Book cover detected")
                _persist_job(job_id, force=True)
            except Exception as cover_exc:
                _append_event(job, f"⚠️ Failed to save cover: {cover_exc}")
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
            _append_event(job, f"🔁 {reason} → trying fallback")

            while engine_index + 1 < len(engine_chain):
                engine_index += 1
                candidate = engine_chain[engine_index]
                engine_name = (candidate.engine or "").lower()
                if not engine_name or engine_name in unavailable_engines:
                    _append_event(job, "   ↳ Engine unavailable, skipping")
                    continue
                _append_event(job, f"   ↳ Activating engine '{candidate.engine}'...")
                active_config = candidate
                _append_event(
                    job,
                    f"   ✅ Now using {candidate.engine.upper()} ({candidate.voice or 'default'})",
                )
                return True
            return False

        zip_lock = asyncio.Lock()
        job_failed = {"value": False}
        edge_slow_mode = False
        # Count consecutive Edge chapter timeouts across all chapters.
        # After _EDGE_TIMEOUT_DISABLE_THRESHOLD failures, Edge is disabled for the whole job
        # so subsequent chapters skip the 60s wait and go straight to the next engine.
        _EDGE_TIMEOUT_DISABLE_THRESHOLD = 2
        edge_chapter_timeouts = [0]  # mutable container for nonlocal mutation in nested fns
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

        audio_duplicate_tracker = AudioDuplicateTracker()

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
                f"🧯 Edge safe mode: {reason} → chunk={edge_safe_profile['chunk_chars']} seg={edge_safe_profile['max_segment_seconds']}s parallel={parallel_slots}",
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
        max_retry_rounds_label = "unlimited" if retry_forever else str(max_retry_rounds)
        max_chapter_attempts_label = "unlimited" if retry_forever else str(max_chapter_attempts)
        retrying_failed_chapters = False

        def _note_chapter_attempt(chapter_index: int) -> int:
            attempt = chapter_attempts.get(chapter_index, 0) + 1
            chapter_attempts[chapter_index] = attempt
            return attempt

        def _chapter_can_retry(chapter_index: int) -> bool:
            attempts = chapter_attempts.get(chapter_index, 0)
            if retry_forever:
                # Hard cap prevents infinite loops when all engines fail permanently
                return attempts < _CHAPTER_RETRY_FOREVER_MAX
            return attempts < max_chapter_attempts

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

        def _chapter_requires_audio(chapter_obj) -> bool:
            chapter_text = getattr(chapter_obj, "speech_text", None) or chapter_obj.text or ""
            return bool(chapter_text and chapter_text.strip())

        def _collect_missing_chapters() -> list[tuple[int, object]]:
            missing: list[tuple[int, object]] = []
            for idx, chapter in enumerate(chapters, 1):
                if not _chapter_requires_audio(chapter):
                    continue
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
                f"🔁 Reprocessing {total_failed} failed chapter(s) (round {round_number}/{max_retry_rounds_label})",
            )
            job["statusHint"] = f"Reprocessing failed chapters ({total_failed})"
            requested_slots = 1
            parallel_slots = 1
            job["parallelSlots"] = parallel_slots
            engine_pool.update_parallel_slots(parallel_slots)
            for cfg in edge_configs:
                cfg.edge_enable_parallel = False
            _apply_edge_slow_mode("retry for failed chapters")
            _persist_job(job_id, force=True)

        async def convert_chapter(idx: int, chapter_obj) -> None:
            if job_failed["value"] or _should_abort_current_run():
                return

            attempt = _note_chapter_attempt(idx)

            chapter_name = getattr(chapter_obj, "name", f"Chapter {idx}")
            job["_currentChapterIndex"] = idx
            job["currentChapter"] = chapter_name
            job["parallelActive"] = job.get("parallelActive", 0) + 1
            job["statusHint"] = f"Chapter {idx}/{len(chapters)}: {chapter_name}"
            start_time = time.time()
            heartbeat_stop = asyncio.Event()
            heartbeat_task: Optional[asyncio.Task] = None
            _update_job_activity(job, stage=f"chapter_{idx}_start")

            try:
                if attempt > 1:
                    _append_event(
                        job,
                        f"🔁 Reprocessing chapter {idx}/{len(chapters)} (attempt {attempt}/{max_chapter_attempts_label})",
                    )
                    # Set retrying status with info
                    _set_chapter_status(
                        job,
                        idx,
                        "retrying",
                        engine_label=(config.engine or "auto"),
                        retry_count=attempt - 1,
                        max_retries=max_chapter_attempts,
                        retry_reason="Previous failure",
                        param_adjustment="Reduced parameters",
                    )
                else:
                    _set_chapter_status(
                        job,
                        idx,
                        "processing",
                        engine_label=(config.engine or "auto"),
                    )
                _append_event(job, "")
                _append_event(job, f"🎯 Converting chapter {idx}/{len(chapters)}: {chapter_name}")

                safe_name = FileManager.sanitize_filename(chapter_name)
                output_file = job_output_dir / f"{idx:03d} - {safe_name}.mp3"
                chapter_text = getattr(chapter_obj, "speech_text", None) or chapter_obj.text or ""

                if not chapter_text or not chapter_text.strip():
                    _append_event(job, "⚠️ Chapter has no audible content, skipped")
                    _set_chapter_status(job, idx, "skipped")
                    _refresh_chapter_completion()
                    _complete_chapter_progress(idx)
                    _update_job_activity(job, stage=f"chapter_{idx}_skipped")
                    return

                clean_text = TextFormattingProcessor.strip_inline_markdown(chapter_text)

                if MAX_CHAPTER_CHARS > 0 and len(clean_text) > MAX_CHAPTER_CHARS:
                    _append_event(
                        job,
                        f"⏭️ Skipping chapter {idx} ({len(clean_text):,} chars >"
                        f" MAX_CHAPTER_CHARS={MAX_CHAPTER_CHARS:,}): {chapter_name[:60]}",
                    )
                    _set_chapter_status(job, idx, "skipped")
                    _refresh_chapter_completion()
                    _complete_chapter_progress(idx)
                    _update_job_activity(job, stage=f"chapter_{idx}_skipped_oversized")
                    return

                preview = _build_text_preview(clean_text)
                if preview:
                    _append_event(job, f"📝 Excerpt: {preview}")

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
                        _append_event(job, "❌ No engine available in automatic mode")
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
                    _append_event(job, f"⚡ AUTO: using {selected_engine.upper()} for this chapter")
                    _set_chapter_status(
                        job,
                        idx,
                        "processing",
                        engine_label=selected_engine,
                    )
                    est = TextValidator.estimate_duration(clean_text)
                    if est <= 0:
                        est = max(len(clean_text) / 15.0, 30.0)
                    _append_event(
                        job,
                        f"   ↳ Text: {len(clean_text)} chars, estimated {TimeFormatter.format_time(est)}",
                    )

                estimated_seconds = TextValidator.estimate_duration(clean_text)
                if estimated_seconds <= 0:
                    estimated_seconds = max(len(clean_text) / 15.0, 30.0)

                retry_count = 0

                def _edge_retry_adjustments(edge_config, attempt: int) -> dict[str, float]:
                    # Research-based default: 8k chars
                    chunk = int(getattr(edge_config, "edge_chunk_chars", 8000) or 8000)
                    seg = float(getattr(edge_config, "edge_max_segment_seconds", 75) or 75)
                    factor = 0.75 ** max(1, attempt)
                    chunk = max(1200, int(chunk * factor))  # allow deeper retries
                    seg = max(30.0, min(seg, seg * (0.85 ** max(1, attempt))))
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
                    # If a fallback engine is available, prefer switching instead of retrying
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
                            f"🔧 Edge fallback: chunk={engine_config.edge_chunk_chars} seg={engine_config.edge_max_segment_seconds}s parallel=off",
                        )
                    elif (engine_label or "").lower().startswith("coqui"):
                        if hasattr(engine_config, "coqui_chunk_chars"):
                            old_chunk = int(getattr(engine_config, "coqui_chunk_chars") or 0)
                            new_chunk = max(800, int(max(old_chunk, 1200) * 0.75))
                            engine_config.coqui_chunk_chars = new_chunk
                            config.coqui_chunk_chars = new_chunk
                            _append_event(
                                job,
                                f"🔧 Coqui fallback: chunk={new_chunk} (before {old_chunk or 'auto'})",
                            )
                    if parallel_slots > 1:
                        parallel_slots = max(1, parallel_slots - 1)
                        engine_pool.update_parallel_slots(parallel_slots)
                        job["parallelSlots"] = parallel_slots
                        _append_event(
                            job,
                            f"⚙️ Reducing parallelism to {parallel_slots} after {reason}",
                        )
                    if backoff > 0:
                        await asyncio.sleep(backoff)
                    _append_event(
                        job,
                        f"🔁 Retrying ({retry_count}/{_CHAPTER_RETRY_MAX}) after {reason}",
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
                                in_progress = TimeFormatter.format_time(elapsed)
                                remaining = max(0.0, estimated_seconds - elapsed)
                                hint = f"Chapter {idx}/{len(chapters)}: {chapter_name} for {TimeFormatter.format_time(elapsed)}"
                                if remaining > 0:
                                    hint += f" • estimated remaining {TimeFormatter.format_time(remaining)}"
                                job["statusHint"] = hint
                                _append_event(
                                    job,
                                    f"⏳ {chapter_name}: {in_progress} using {engine_label.upper()}",
                                )
                                # Keep _lastActivityTs fresh during rate-limit backoff
                                # so the stall watchdog doesn't trigger false positives.
                                _update_job_activity(job)
                                _persist_job(job_id, force=False)
                    finally:
                        job.pop("statusHint", None)

                heartbeat_task = asyncio.create_task(_chapter_heartbeat_loop())

                while True:
                    if _should_abort_current_run(
                        f"🛑 Conversion cancelled during chapter {chapter_name}"
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
                                use_engine = engine_config.engine or engine_name or "unknown"
                                _append_event(
                                    job,
                                    f"   ⚠️ {chapter_name}: timeout of  {int(chapter_timeout)}s exceeded on {use_engine}",
                                )
                                job["statusHint"] = (
                                    f"Chapter {idx}/{len(chapters)} delayed on {use_engine.upper()} (timeout)"
                                )
                                # Track consecutive Edge timeouts job-wide so subsequent
                                # chapters skip the 60s wait if Edge is consistently broken.
                                if use_engine == "edge":
                                    edge_chapter_timeouts[0] += 1
                                    if edge_chapter_timeouts[0] >= _EDGE_TIMEOUT_DISABLE_THRESHOLD:
                                        unavailable_engines.add("edge")
                                        _append_event(
                                            job,
                                            f"🚫 Edge disabled for job after "
                                            f"{edge_chapter_timeouts[0]} consecutive timeouts "
                                            f"— remaining chapters skip Edge",
                                        )
                                if await _maybe_retry(
                                    reason=f"timeout on {use_engine}",
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
                                            f"   ↳ AUTO: switching to {next_engine.upper()} after timeout",
                                        )
                                        continue
                                if _switch_to_next_engine(
                                    f"Synthesizer {use_engine.upper()} stalled for {int(chapter_timeout)}s"
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
                                    "timeout exceeded",
                                    chapter_index=idx,
                                    fatal=False,
                                ):
                                    job_failed["value"] = True
                                return
                            except Exception as exc:
                                if await _maybe_retry(
                                    reason=f"error in {engine_config.engine if engine_config else 'engine'}",
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
                                            f"   ↳ AUTO: switching to {next_engine.upper()} after error ({exc})",
                                        )
                                        continue
                                if _switch_to_next_engine(
                                    f"Engine {engine_config.engine if engine_config else config.engine} failed ({exc})"
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
                                                f"   ↳ AUTO: switching to {next_engine.upper()} after WAV→MP3 conversion failure",
                                            )
                                            continue
                                    if _switch_to_next_engine("WAV→MP3 conversion failed"):
                                        local_active_config = active_config
                                        local_engine_name = (
                                            active_config.engine if active_config else config.engine
                                        ) or "auto"
                                        continue
                                    if _record_chapter_failure(
                                        job,
                                        engine_obj,
                                        chapter_name,
                                        "failed to convert WAV to MP3",
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
                                            job, "   ↳ AUTO: empty audio; trying another engine"
                                        )
                                        continue
                                if _switch_to_next_engine("Empty or missing audio"):
                                    local_active_config = active_config
                                    local_engine_name = (
                                        active_config.engine if active_config else config.engine
                                    ) or "auto"
                                    continue
                                if _record_chapter_failure(
                                    job,
                                    engine_obj,
                                    chapter_name,
                                    "audio was not generated by the voice service",
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
                                    f"   ↳ AUTO: switching to {next_engine.upper()} after failed to start ({exc})",
                                )
                                continue
                        if _switch_to_next_engine(f"Engine unavailable ({exc})"):
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
                    duration_seconds = await _get_audio_duration(output_file)
                    chapter_elapsed = time.time() - start_time

                    engine_label = (
                        (local_active_config.engine if local_active_config else None)
                        or engine_name
                        or "auto"
                    )
                    truncation_warning = _detect_short_audio_output(
                        clean_text, duration_seconds, engine_label=engine_label
                    )
                    if truncation_warning:
                        _append_event(job, f"⚠️ {truncation_warning}")
                        if hasattr(engine_obj, "last_error"):
                            setattr(engine_obj, "last_error", "short_output")
                        with contextlib.suppress(OSError):
                            output_file.unlink(missing_ok=True)
                        if await _maybe_retry(
                            reason="truncated audio",
                            engine_label=engine_label,
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
                                    "   ↳ AUTO: truncated audio; trying another engine",
                                )
                                continue
                        if _switch_to_next_engine("Truncated audio"):
                            local_active_config = active_config
                            local_engine_name = (
                                active_config.engine if active_config else config.engine
                            ) or "auto"
                            continue
                        if _record_chapter_failure(
                            job,
                            engine_obj,
                            chapter_name,
                            truncation_warning,
                            chapter_index=idx,
                            fatal=False,
                        ):
                            job_failed["value"] = True
                        return
                    duplicate_entry = None
                    try:
                        duplicate_entry = await audio_duplicate_tracker.check_duplicate(
                            output_file, clean_text, idx, chapter_name
                        )
                    except Exception as exc:
                        _append_event(
                            job,
                            f"⚠️ Failed to validate duplicate audio: {exc}",
                        )

                    if duplicate_entry:
                        duplicate_msg = (
                            "Duplicate audio detected: "
                            f"same content as chapter {duplicate_entry.get('index')} "
                            f"({duplicate_entry.get('name')})"
                        )
                        _append_event(job, f"⚠️ {duplicate_msg}")
                        with contextlib.suppress(OSError):
                            output_file.unlink(missing_ok=True)
                        if await _maybe_retry(
                            reason="duplicate audio",
                            engine_label=engine_label,
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
                                    "   ↳ AUTO: duplicate audio; trying another engine",
                                )
                                continue
                        if _switch_to_next_engine("Duplicate audio detected"):
                            local_active_config = active_config
                            local_engine_name = (
                                active_config.engine if active_config else config.engine
                            ) or "auto"
                            continue
                        if _record_chapter_failure(
                            job,
                            engine_obj,
                            chapter_name,
                            duplicate_msg,
                            chapter_index=idx,
                            fatal=False,
                        ):
                            job_failed["value"] = True
                        return
                    break

                engine_runtime = max((last_stage_timestamp - synth_started), 0.001)

                _append_event(
                    job,
                    f"✅ Completed: {output_file.name} ({TimeFormatter.format_time(chapter_elapsed)})",
                )
                # Successful Edge chapter resets the consecutive timeout counter.
                if (local_active_config and local_active_config.engine or "").lower() == "edge":
                    edge_chapter_timeouts[0] = 0

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
                    engine_label=(
                        local_active_config.engine
                        if local_active_config
                        else local_engine_name or config.engine
                    ),
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

                # Write a lightweight progress checkpoint every 5 chapters so
                # _preload_existing_outputs can recover quickly without scanning all MP3s.
                if should_persist:
                    _write_progress_checkpoint(job_id, job, job_output_dir)

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
                        _apply_edge_slow_mode(f"low speed ({chars_per_second:.1f} chars/s)")
            finally:
                heartbeat_stop.set()
                if heartbeat_task:
                    with contextlib.suppress(asyncio.CancelledError):
                        await heartbeat_task
                job.pop("statusHint", None)
                job["parallelActive"] = max(job.get("parallelActive", 1) - 1, 0)

        _append_event(job, "")
        _append_event(job, "🚀 Starting chapter conversion...")
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
                _append_event(job, f"⚙️ Adjusting parallelism {parallel_slots}→{new_slots}")
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
                if not edge_slow_mode:
                    _apply_edge_slow_mode(f"healthcheck low speed ({recent_speed:.1f} chars/s)")
                else:
                    # Already in slow mode and still slow: disable Edge for the whole job
                    # so remaining chapters skip directly to the next engine.
                    if "edge" not in unavailable_engines:
                        unavailable_engines.add("edge")
                        _append_event(
                            job,
                            f"🚫 Edge persistently slow ({recent_speed:.1f} chars/s in safe mode)"
                            f" — disabling Edge for remaining chapters",
                        )
            elif (
                slow_streak >= health_slow_streak_limit
                and parallel_slots > 1
                and (cpu_percent > health_high_cpu or mem_percent > health_high_mem)
            ):
                new_slots = max(1, parallel_slots - 1)
                if new_slots != parallel_slots:
                    _append_event(
                        job, f"🧪 Healthcheck: reducing parallelism {parallel_slots}→{new_slots}"
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
                        job, f"🧪 Healthcheck: adjusting parallelism {parallel_slots}→{desired}"
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
                        _append_event(job, f"❌ Unexpected error while converting chapter: {exc}")
                        _persist_job(job_id, force=True)
                _maybe_adjust_parallel_slots()

            if job.get("cancelRequested") or job.get("_run_token") != run_token:
                break
            if job_failed["value"]:
                break

            failed_chapters = _collect_failed_chapters()
            missing_chapters = _collect_missing_chapters()
            if missing_chapters:
                expected_count = sum(1 for chapter in chapters if _chapter_requires_audio(chapter))
                actual_count = len(
                    [
                        path
                        for path in job_output_dir.glob("*.mp3")
                        if not path.name.lower().startswith("tmp")
                    ]
                )
                _append_event(
                    job,
                    f"🔍 Verifying final files: {actual_count}/{expected_count} found; reprocessing pending chapters",
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
                f"#{idx} {getattr(chapter, 'name', f'Chapter {idx}')}"
                for idx, chapter in failed_chapters[:3]
            )
            if len(failed_chapters) > 3:
                preview += f" … (+{len(failed_chapters) - 3})"
            failure_message = f"{len(failed_chapters)} chapter(s) failed after {max_chapter_attempts_label} attempt(s)."
            _append_event(job, f"❌ {failure_message}")
            if preview:
                _append_event(job, f"   ↳ Chapters: {preview}")
            job["state"] = "failed"
            _set_job_error(job, failure_message)
            job["completedAt"] = time.time()
            job["completedAtIso"] = _utcnow_iso()
            job["parallelActive"] = 0
            _persist_job(job_id, force=True)
            _persist_job_log(job_id, job)
            return

        retrying_failed_chapters = False

        _cleanup_output_directory(job_output_dir)
        _update_job_activity(job, stage="chapters_done")

        if _should_abort_current_run("🛑 Conversion cancelled during processing"):
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
                f"⚠️ {len(soft_failures)} chapter(s) failed and were skipped automatically."
            )
            if preview:
                summary_line += f" ({preview})"
            _append_event(job, summary_line)

        if zip_open:
            with contextlib.suppress(Exception):
                zip_archive.close()
            zip_open = False

        # Rebuild ZIP to include all available chapters (including resumed ones)
        _append_event(job, "📦 Packing chapters into final ZIP...")
        _update_job_activity(job, stage="building_zip")
        _persist_job(job_id, force=True)
        try:
            with zipfile.ZipFile(zip_file, "w", zipfile.ZIP_STORED) as rebuilt_zip:
                for mp3_path in sorted(job_output_dir.glob("*.mp3")):
                    if mp3_path.name.lower().startswith("tmp"):
                        continue
                    rebuilt_zip.write(mp3_path, arcname=mp3_path.name)
            _append_event(job, "✅ Final ZIP ready")
        except Exception as exc:
            _append_event(job, f"⚠️ Failed to pack ZIP: {exc}")

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

        # Local storage - files are served from local output directory
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

        # Persistent conversion session log
        try:
            from src.session_logger import log_session

            _ch_total = job.get("chaptersTotal") or 0
            _ch_done = job.get("chaptersCompleted") or 0
            _chapter_details = _extract_chapter_details(job)
            log_session(
                book_title=job.get("bookTitle", ""),
                book_author=job.get("bookAuthor", ""),
                language=job.get("detectedLanguage", ""),
                engine=job.get("engine", ""),
                voice=job.get("voice", ""),
                chapters_total=_ch_total,
                chapters_converted=_ch_done,
                chapters_failed=_ch_total - _ch_done,
                duration_seconds=total_elapsed,
                outcome="success",
                job_id=job_id,
                output_dir=str(job.get("outputDir", "")),
                started_at=job.get("startedAt", ""),
                chapter_details=_chapter_details or None,
            )
        except Exception:
            pass  # Never let logging break a conversion
        _append_event(job, "")
        _append_event(job, "✅ Conversion completed successfully")
        _append_event(job, f"⏱️ Total conversion time: {TimeFormatter.format_time(total_elapsed)}")
        _append_event(job, f"📁 File available: {zip_file.name} ({len(chapters)} chapters)")
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
        logger.exception("Job %s failed with unhandled error", job_id)
        job["state"] = "failed"
        _set_job_error(job, str(exc))
        job["completedAt"] = time.time()  # Timestamp for cleanup
        job["completedAtIso"] = _utcnow_iso()
        _update_job_activity(job, stage="failed")
        _append_event(job, f"❌ Error: {exc}")
        job["parallelActive"] = 0
        _persist_job(job_id)
        _persist_job_log(job_id, job)

        # Persistent conversion session log
        try:
            from src.session_logger import log_session

            _elapsed = time.time() - conversion_started
            _ch_total = job.get("chaptersTotal") or 0
            _ch_done = job.get("chaptersCompleted") or 0
            _chapter_details = _extract_chapter_details(job)
            log_session(
                book_title=job.get("bookTitle", ""),
                book_author=job.get("bookAuthor", ""),
                language=job.get("detectedLanguage", ""),
                engine=job.get("engine", ""),
                voice=job.get("voice", ""),
                chapters_total=_ch_total,
                chapters_converted=_ch_done,
                chapters_failed=_ch_total - _ch_done,
                duration_seconds=_elapsed,
                outcome="failed",
                job_id=job_id,
                output_dir=str(job.get("outputDir", "")),
                started_at=job.get("startedAt", ""),
                chapter_details=_chapter_details or None,
                extra={"error": str(exc)},
            )
        except Exception:
            pass  # Never let logging break a conversion

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


def _hash_audio_file(path: Path) -> str:
    hasher = hashlib.sha1()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def _hash_text_payload(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8", errors="ignore")).hexdigest()


class AudioDuplicateTracker:
    def __init__(self) -> None:
        self._hashes: dict[str, dict] = {}
        self._lock = asyncio.Lock()

    async def check_duplicate(
        self,
        audio_path: Path,
        text: str,
        chapter_index: int,
        chapter_name: str,
    ) -> Optional[dict]:
        text_len = len(text or "")
        if text_len < MIN_DUPLICATE_CHARS:
            return None
        text_hash = _hash_text_payload(text)
        audio_hash = _hash_audio_file(audio_path)
        async with self._lock:
            existing = self._hashes.get(audio_hash)
            if (
                existing
                and existing.get("text_hash") != text_hash
                and existing.get("text_len", 0) >= MIN_DUPLICATE_CHARS
            ):
                return existing
            self._hashes[audio_hash] = {
                "index": chapter_index,
                "name": chapter_name,
                "text_hash": text_hash,
                "text_len": text_len,
            }
        return None


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


def _detect_short_audio_output(
    text: str,
    duration_seconds: float,
    *,
    engine_label: Optional[str] = None,
) -> Optional[str]:
    """Return warning text when audio looks far shorter than expected."""
    if not text or duration_seconds <= 0:
        return None

    engine = (engine_label or "").lower()
    if engine != "edge":
        return None

    stripped = text.strip()
    if len(stripped) < 2000:
        return None

    estimated_seconds = TextValidator.estimate_duration(stripped)
    if estimated_seconds < 150:
        return None

    if duration_seconds >= estimated_seconds * 0.60:
        return None
    if duration_seconds >= max(estimated_seconds - 90, estimated_seconds * 0.5):
        return None

    return (
        "Audio possibly truncated "
        f"({int(duration_seconds)}s, expected ≈ {int(estimated_seconds)}s)"
    )


def _set_chapter_status(
    job: dict,
    chapter_index: Optional[int],
    status: str,
    download_url: Optional[str] = None,
    engine_label: Optional[str] = None,
    *,
    retry_count: Optional[int] = None,
    max_retries: Optional[int] = None,
    retry_reason: Optional[str] = None,
    param_adjustment: Optional[str] = None,
    error_message: Optional[str] = None,
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
                if engine_label:
                    entry["engine"] = str(engine_label).lower()
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
                # Per-chapter timing timestamps
                if status == "processing" and "startedAt" not in entry:
                    entry["startedAt"] = _utcnow_iso()
                    entry["engineSequence"] = [str(engine_label).lower()] if engine_label else []
                elif status == "retrying" and engine_label:
                    seq = entry.setdefault("engineSequence", [])
                    eng = str(engine_label).lower()
                    if not seq or seq[-1] != eng:
                        seq.append(eng)
                elif status in ("completed", "failed", "skipped"):
                    entry["completedAt"] = _utcnow_iso()
                # Structured error classification
                if status == "failed":
                    from src.error_classifier import classify_error

                    err_text = error_message or retry_reason or ""
                    if error_message:
                        entry["errorMessage"] = error_message
                    entry["errorCategory"] = classify_error(err_text)
    if isinstance(entries, list):
        processing = sum(
            1
            for entry in entries
            if isinstance(entry, dict) and entry.get("status") in ("processing", "retrying")
        )
        job["parallelActive"] = processing

    # Emit a lean per-chapter SSE event so the frontend can update just that card
    job_id = job.get("jobId")
    if job_id and isinstance(entries, list) and chapter_index is not None:
        idx = max(0, int(chapter_index) - 1)
        if idx < len(entries) and isinstance(entries[idx], dict):
            _schedule_chapter_broadcast(job_id, dict(entries[idx]))


def _set_job_error(job: dict, message: str) -> None:
    """Set job error string and auto-classify it into a stable category."""
    from src.error_classifier import classify_error

    job["error"] = message
    job["errorCategory"] = classify_error(message)


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


_PROGRESS_CHECKPOINT_NAME = "_progress_checkpoint.json"


def _write_progress_checkpoint(job_id: str, job: dict, job_output_dir: Path) -> None:
    """Persist a lightweight checkpoint with completed chapter indices.

    Written every N chapters (same cadence as _persist_job) so that
    _preload_existing_outputs can recover instantly without scanning MP3 files.
    """
    try:
        entries = job.get("chapterProgress") or []
        completed = [
            e.get("index")
            for e in entries
            if isinstance(e, dict)
            and e.get("status") in ("completed", "skipped")
            and e.get("index") is not None
        ]
        record = {
            "job_id": job_id,
            "timestamp": _utcnow_iso(),
            "completed_indices": completed,
            "last_completed": max(completed) if completed else 0,
            "total_chapters": job.get("chaptersTotal") or 0,
            "engine": job.get("engine", ""),
            "voice": job.get("voice", ""),
        }
        checkpoint_path = job_output_dir / _PROGRESS_CHECKPOINT_NAME
        checkpoint_path.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
    except Exception:
        pass  # Checkpoint is best-effort; never break a conversion


def _extract_chapter_details(job: dict) -> list[dict]:
    """Extract per-chapter timing/engine data from job chapterProgress for session log."""
    entries = job.get("chapterProgress")
    if not isinstance(entries, list):
        return []
    details = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        detail: dict = {
            "index": entry.get("index"),
            "name": entry.get("name", ""),
            "status": entry.get("status", ""),
            "engine": entry.get("engine", ""),
            "chars": entry.get("textLength") or entry.get("chars"),
        }
        if entry.get("startedAt"):
            detail["startedAt"] = entry["startedAt"]
        if entry.get("completedAt"):
            detail["completedAt"] = entry["completedAt"]
        if entry.get("elapsedSeconds") is not None:
            detail["elapsedSeconds"] = entry["elapsedSeconds"]
        if entry.get("charsPerSecond") is not None:
            detail["charsPerSecond"] = entry["charsPerSecond"]
        if entry.get("engineSequence"):
            detail["engineSequence"] = entry["engineSequence"]
        if entry.get("retryCount"):
            detail["retryCount"] = entry["retryCount"]
        if entry.get("retryReason"):
            detail["retryReason"] = entry["retryReason"]
        if entry.get("errorCategory"):
            detail["errorCategory"] = entry["errorCategory"]
        if entry.get("errorMessage"):
            detail["errorMessage"] = entry["errorMessage"]
        # Remove None values to keep log compact
        details.append({k: v for k, v in detail.items() if v is not None})
    return details


async def _preload_existing_outputs(
    job: dict, chapters: list, job_output_dir: Path
) -> tuple[list[dict], set[int]]:
    """Detect chapters that already have audio on disk (resume support).

    First checks the progress checkpoint written during a previous run for a
    fast path: only those chapter indices are verified on disk.  Falls back to
    scanning all chapter files when no checkpoint exists.
    """
    existing_outputs: list[dict] = []
    completed_indices: set[int] = set()
    job_id = job.get("jobId")

    # Fast path: use checkpoint to know which indices to verify
    checkpoint_indices: set[int] = set()
    checkpoint_path = job_output_dir / _PROGRESS_CHECKPOINT_NAME
    if checkpoint_path.exists():
        try:
            ckpt = json.loads(checkpoint_path.read_text(encoding="utf-8"))
            checkpoint_indices = {int(i) for i in (ckpt.get("completed_indices") or [])}
        except Exception:
            checkpoint_indices = set()

    # Determine which chapter indices to probe
    all_indices = range(1, len(chapters) + 1)
    probe_indices = checkpoint_indices if checkpoint_indices else set(all_indices)

    for idx, chapter in enumerate(chapters, 1):
        if idx not in probe_indices:
            continue
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
        _set_chapter_status(
            job,
            idx,
            "completed",
            download_url=download_url,
            engine_label=job.get("engine"),
        )

    # If we used checkpoint but some indices are missing on disk, fall back to
    # a full scan so we don't miss chapters that exist but weren't checkpointed.
    if checkpoint_indices and len(existing_outputs) < len(checkpoint_indices):
        for idx, chapter in enumerate(chapters, 1):
            if idx in completed_indices or idx in probe_indices:
                continue
            chapter_name = getattr(chapter, "name", f"Chapter {idx}")
            safe_name = FileManager.sanitize_filename(chapter_name)
            output_file = job_output_dir / f"{idx:03d} - {safe_name}.mp3"
            if not output_file.exists() or output_file.stat().st_size <= 0:
                continue
            duration = await _get_audio_duration(output_file)
            download_url = (
                f"/api/outputs/{job_id}/{output_file.name}" if job_id else output_file.name
            )
            entry = {
                "name": output_file.name,
                "url": download_url,
                "durationSeconds": round(duration, 2),
                "sizeBytes": output_file.stat().st_size,
            }
            existing_outputs.append(entry)
            completed_indices.add(idx)
            _set_chapter_status(
                job,
                idx,
                "completed",
                download_url=download_url,
                engine_label=job.get("engine"),
            )

    return existing_outputs, completed_indices


def _record_chapter_failure(
    job: dict,
    tts_engine,
    chapter_name: str,
    error: object,
    chapter_index: Optional[int] = None,
    fatal: bool = True,
) -> bool:
    last_error = getattr(tts_engine, "last_error", None)
    error_message = str(error) if error else "unknown error"
    if isinstance(error, FileNotFoundError):
        failure_detail = last_error or "Edge TTS did not create an audio file"
    else:
        failure_detail = last_error or error_message
    _set_chapter_status(job, chapter_index, "failed", error_message=failure_detail)
    _append_event(job, "")
    _append_event(job, f"❌ Chapter synthesis failed for '{chapter_name}': {failure_detail}")
    if error:
        error_type = getattr(error, "__class__", type(error)).__name__
    else:
        error_type = "UnknownError"

    if last_error and error_message and last_error != error_message:
        _append_event(job, f"   ↳ Internal error ({error_type}): {error_message}")
    elif not last_error and error_message:
        _append_event(job, f"   ↳ Internal error ({error_type}): {error_message}")
    failure_payload = {
        "chapter": chapter_name,
        "index": chapter_index,
        "detail": failure_detail,
    }
    if fatal:
        job["state"] = "failed"
        _set_job_error(job, f"Chapter synthesis failed for '{chapter_name}': {failure_detail}")
        job.setdefault("outputs", [])

        job_id = job.get("jobId")
        if job_id:
            _persist_job_log(job_id, job)

        _clear_job_cache(job)
    else:
        soft_failures = job.setdefault("softFailures", [])
        if isinstance(soft_failures, list):
            soft_failures.append(failure_payload)
        _append_event(job, "   ↳ Chapter marked as failed; moving to the next one.")
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
    reader: EbookReader,
    config: ConversionConfig,
    selectors: Optional[str] = None,
    *,
    range_start: Optional[str] = None,
    range_span: Optional[str] = None,
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

    if range_start or range_span:
        try:
            if range_start and range_span:
                range_span = None
            if range_span:
                parsed = converter_app._parse_range_selector(range_span)
                if parsed:
                    range_start, range_end = parsed
                else:
                    range_start, range_end = None, None
            else:
                range_end = None
            if range_start:
                filtered_items, filtered = converter_app._filter_structure_range(
                    structure_items, range_start, range_end
                )
                if filtered and filtered_items:
                    structure_items = filtered_items
        except Exception:
            pass

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
    raise HTTPException(status_code=404, detail="Sample EPUB unavailable")


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
