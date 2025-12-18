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

logger = logging.getLogger(__name__)

from fastapi import BackgroundTasks, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
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

app = FastAPI(title="EPUB to MP3 Converter API")

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

# Para deployments em cloud (HF Spaces, etc.), use /tmp; caso contrário, usa OUTPUT_DIR da raiz do projeto
# Se OUTPUT_DIR env var estiver definida, usa ela; senão usa OUTPUT_DIR do paths.py
if os.getenv("OUTPUT_DIR"):
    output_dir = Path(os.getenv("OUTPUT_DIR"))
elif os.getenv("SPACE_ID"):  # HuggingFace Spaces
    output_dir = Path("/tmp/output")
else:
    output_dir = OUTPUT_DIR

output_dir.mkdir(exist_ok=True, parents=True)
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
jobs_state_dir = output_dir / ".jobs"
job_manager = JobManager(jobs_state_dir)


def _summarize_resume_job(job_id: str, job_data: dict, saved_at: Optional[str] = None) -> dict:
    return {
        "jobId": job_id,
        "state": job_data.get("state", "queued"),
        "bookTitle": job_data.get("bookTitle", "Livro Desconhecido"),
        "fileName": Path(job_data.get("file_path", "")).name if job_data.get("file_path") else "unknown",
        "savedAt": saved_at or job_data.get("_saved_at") or datetime.utcnow().isoformat(),
        "chaptersCompleted": job_data.get("chaptersCompleted", 0),
        "chaptersTotal": job_data.get("chaptersTotal"),
    }


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

# Load existing jobs from disk on startup
jobs: Dict[str, dict] = job_manager.load_all_jobs()
logger.info(f"Loaded {len(jobs)} jobs from disk")

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
    for name in ("coqui", "edge", "piper"):
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
) -> tuple[str, list[str]]:
    def append(order: list[str], candidate: str) -> None:
        if candidate in pool and candidate not in order:
            order.append(candidate)

    # Ordem do mais rápido para mais lento: edge > piper > coqui
    # Testado com 3053 chars: edge=21s (144 chars/s), piper=27s (112 chars/s), coqui=113s (26 chars/s)
    order: list[str] = []
    if telemetry_speeds:
        ranked = sorted(
            ((name, telemetry_speeds.get(name, 0.0)) for name in pool.keys()),
            key=lambda item: item[1],
            reverse=True,
        )
        for name, _ in ranked:
            append(order, name)
    append(order, "edge")
    append(order, "piper")
    append(order, "coqui")

    if not order:
        order = list(pool.keys())

    selected = order[0]
    return selected, order


def _next_auto_engine(order: list[str], attempted: set[str], pool: dict[str, tuple[ConversionConfig, object]]) -> Optional[str]:
    for name in order:
        if name in pool and name not in attempted:
            return name
    return None




class JobStatus(BaseModel):
    jobId: str
    state: str
    events: list[str] = []
    detectedLanguage: Optional[str] = None
    chaptersTotal: Optional[int] = None
    chaptersCompleted: Optional[int] = None
    currentChapter: Optional[str] = None
    progressPercent: Optional[float] = None
    chapterProgress: Optional[list[dict]] = None
    outputs: list[dict] = []
    error: Optional[str] = None
    bookTitle: Optional[str] = None
    bookAuthor: Optional[str] = None
    coverUrl: Optional[str] = None
    coverMimeType: Optional[str] = None
    logUrl: Optional[str] = None


@app.post("/api/convert")
async def convert_ebook(
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
    engine: str = Form("auto"),
    voice: Optional[str] = Form(None),
    chapters: Optional[str] = Form(None),
    footnote_mode: Optional[str] = Form("inline"),
    language: Optional[str] = Form(None),
    priority: Optional[str] = Form(None),
) -> dict[str, str]:
    job_id = f"{uuid.uuid4()}"
    temp_file = output_dir / f"{job_id}_{file.filename}"

    raw_payload = await file.read()
    if MAX_UPLOAD_BYTES and len(raw_payload) > MAX_UPLOAD_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"Arquivo excede o limite de {MAX_UPLOAD_MB} MB",
        )
    with temp_file.open("wb") as buffer:
        buffer.write(raw_payload)
    file_hash = hashlib.sha1(raw_payload).hexdigest() if raw_payload else None

    jobs[job_id] = {
        "jobId": job_id,
        "state": "queued",
        "events": ["📚 Arquivo recebido, aguardando processamento..."],
        "file_path": str(temp_file),
        "engine": engine,
        "voice": voice,
        "chapters": chapters,
        "footnote_mode": footnote_mode,
        "language": language,
        "priority": priority,
        "outputs": [],
        "bookTitle": None,
        "bookAuthor": None,
        "cover": None,
        "coverUrl": None,
        "coverMimeType": None,
        "cancelRequested": False,
        "fileHash": file_hash,
    }

    # Persist job state to disk
    job_manager.save_job(job_id, jobs[job_id])

    background_tasks.add_task(process_conversion, job_id)
    return {"jobId": job_id}


@app.get("/api/jobs/{job_id}")
async def get_job_status(job_id: str) -> JobStatus:
    # Check in-memory jobs first
    if job_id in jobs:
        return JobStatus(**jobs[job_id])

    # Try to load from disk if not in memory
    job_data = job_manager.load_job(job_id)
    if job_data:
        # Add back to memory cache for future requests
        jobs[job_id] = job_data
        return JobStatus(**job_data)

    raise HTTPException(status_code=404, detail="Job not found")


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
        job["events"].append("🛑 Cancelamento solicitado. Finalizando capítulo atual…")
        _persist_job(job_id, force=True)

    return {"status": job["state"]}


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


def _persist_job(job_id: str, force: bool = False) -> None:
    """
    Helper to persist job state to disk.

    Args:
        job_id: Job ID to persist
        force: If True, persist immediately. If False, only persist important state changes.
    """
    if job_id in jobs and force:
        job_manager.save_job(job_id, jobs[job_id])


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
        job["events"].append(note)
    job["events"].append("🛑 Conversão cancelada pelo usuário")
    job["state"] = "cancelled"
    job["error"] = "Cancelado pelo usuário"
    job["cancelRequested"] = True
    job["currentChapter"] = None
    job["outputs"] = []
    job["progressPercent"] = job.get("progressPercent") or 0.0
    _cleanup_job_output(job_id)
    _clear_job_cache(job)
    _persist_job(job_id, force=True)
    try:
        job_manager.delete_job(job_id)
    except Exception:
        pass
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
        log_path.write_text("\n".join(job.get("events", [])), encoding="utf-8")
        job["logUrl"] = f"/api/outputs/{job_id}/{log_path.name}"
        return log_path
    except Exception:
        return None


async def process_conversion(job_id: str) -> None:
    job = jobs[job_id]
    zip_archive: Optional[zipfile.ZipFile] = None
    zip_open = False

    try:
        if job.get("cancelRequested"):
            _finalize_cancel(job_id, job, "🛑 Conversão cancelada antes de iniciar")
            return

        job["state"] = "running"
        job["events"].append("📚 METADADOS DO EBOOK")
        job["events"].append("=" * 64)
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

        job["events"].append(f"📜 Título: {title}")
        job["events"].append(f"✍️ Autor: {author}")
        job["chaptersCompleted"] = 0

        job["events"].append("")
        job["events"].append("🌐 DETECÇÃO DE IDIOMA")
        job["events"].append("-" * 64)
        detected_lang = job.get("language") or "pt-BR"
        job["detectedLanguage"] = detected_lang
        job["events"].append(f"🌐 Idioma principal: {detected_lang} (estimado)")
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
        )
        if (config.engine or "").lower() == "edge":
            config.edge_aggressive_mode = True

        selector_text = job.get("chapters")
        chapters = _prepare_chapters(reader, config, selector_text)
        selection_note = " (filtro aplicado)" if selector_text else ""
        job["events"].append(f"📊 Capítulos: {len(chapters)}{selection_note}")
        job["chaptersTotal"] = len(chapters)
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

        engine_chain = _build_engine_chain(config)
        engine_index = 0
        tts_engine = None
        active_config: Optional[ConversionConfig] = None
        auto_mode = (config.engine or "").lower() == "auto"

        auto_engine_pool: dict[str, tuple[ConversionConfig, object]] = {}
        telemetry_speeds: Dict[str, float] = {}

        if not auto_mode:
            while engine_index < len(engine_chain):
                candidate = engine_chain[engine_index]
                try:
                    tts_engine = tts_factory.create_engine(candidate)
                    active_config = candidate
                    break
                except ImportError as exc:
                    job["events"].append(f"⚠️ Engine '{candidate.engine}' indisponível: {exc}")
                except Exception as exc:
                    job["events"].append(f"⚠️ Falha ao iniciar engine '{candidate.engine}': {exc}")
                engine_index += 1

            if tts_engine is None or active_config is None:
                job["state"] = "failed"
                job["error"] = "Nenhuma engine TTS disponível"
                job["events"].append("❌ Nenhuma engine TTS disponível para iniciar")
                _persist_job(job_id, force=True)
                return
        else:
            active_config = config
            auto_engine_pool = _prepare_auto_engine_pool(config)
            if not auto_engine_pool:
                job["state"] = "failed"
                job["error"] = "Nenhuma engine disponível no modo automático"
                job["events"].append("❌ Nenhuma engine disponível no modo automático")
                _persist_job(job_id, force=True)
                return

        job["events"].append("")
        job["events"].append(f"🎙️ Engine: {active_config.engine}")
        job["events"].append(f"🗣️ Voz: {active_config.voice or 'padrão'}")

        job_output_dir = output_dir / job_id
        if job_output_dir.exists():
            shutil.rmtree(job_output_dir, ignore_errors=True)
        job_output_dir.mkdir(exist_ok=True)
        book_safe_name = FileManager.sanitize_filename(title)
        zip_file = job_output_dir / f"{book_safe_name}.zip"
        zip_archive = zipfile.ZipFile(zip_file, "w", zipfile.ZIP_STORED)
        zip_open = True

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
                job["events"].append("🖼️ Capa reutilizada do cache")
                _persist_job(job_id, force=True)
            except Exception as cover_exc:
                job["events"].append(f"⚠️ Falha ao reutilizar capa: {cover_exc}")
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
                job["events"].append("🖼️ Capa do livro detectada")
                _persist_job(job_id, force=True)
            except Exception as cover_exc:
                job["events"].append(f"⚠️ Falha ao salvar capa: {cover_exc}")
                job["cover"] = None
                job["coverUrl"] = None
                job["coverMimeType"] = None
        outputs = []

        def _resolve_tts_output(target_mp3: Path, engine_name: str) -> tuple[Path, bool]:
            if engine_name.lower() in {"coqui", "piper"}:
                return target_mp3.with_suffix(".wav"), True
            return target_mp3, False

        def _switch_to_next_engine(reason: str) -> bool:
            nonlocal engine_index, tts_engine, active_config
            if engine_index + 1 >= len(engine_chain):
                return False
            job["events"].append(f"🔁 {reason} → tentando fallback")

            while engine_index + 1 < len(engine_chain):
                engine_index += 1
                candidate = engine_chain[engine_index]
                job["events"].append(f"   ↳ Ativando engine '{candidate.engine}'...")
                try:
                    tts_engine = tts_factory.create_engine(candidate)
                    active_config = candidate
                    job["events"].append(f"   ✅ Agora usando {candidate.engine.upper()} ({candidate.voice or 'padrão'})")
                    return True
                except ImportError as exc:
                    job["events"].append(f"   ⚠️ Engine '{candidate.engine}' indisponível: {exc}")
                except Exception as exc:
                    job["events"].append(f"   ⚠️ Falha ao iniciar '{candidate.engine}': {exc}")
            return False

        for idx, chapter in enumerate(chapters, 1):
            if job.get("cancelRequested"):
                _finalize_cancel(job_id, job, f"🛑 Conversão cancelada antes do capítulo {idx}")
                return

            chapter_name = getattr(chapter, "name", f"Chapter {idx}")
            job["_currentChapterIndex"] = idx
            job["currentChapter"] = chapter_name
            _set_chapter_status(job, idx, "processing")
            job["events"].append("")
            job["events"].append(f"🎯 Convertendo capítulo {idx}/{len(chapters)}: {chapter_name}")

            progress = (idx / len(chapters)) * 100 if chapters else 100
            job["progressPercent"] = progress

            safe_name = FileManager.sanitize_filename(chapter_name)
            output_file = job_output_dir / f"{idx:03d} - {safe_name}.mp3"
            chapter_text = getattr(chapter, "speech_text", None) or chapter.text or ""

            if not chapter_text or not chapter_text.strip():
                job["events"].append("⚠️ Capítulo sem conteúdo audível, ignorado")
                job["chaptersCompleted"] = idx
                _set_chapter_status(job, idx, "skipped")
                job["_currentChapterIndex"] = None
                continue

            # Limpar marcadores Markdown antes de enviar ao TTS
            clean_text = TextFormattingProcessor.strip_inline_markdown(chapter_text)
            preview = _build_text_preview(clean_text)
            if preview:
                job["events"].append(f"📝 Trecho: {preview}")
            auto_order: list[str] = []
            attempted_auto: set[str] = set()
            chapter_clock_start = time.time()
            engine_runtime: Optional[float] = None
            if auto_mode:
                if not telemetry_speeds:
                    summary = telemetry.summary()
                    telemetry_speeds = {name: stats.get("avg_chars_per_second", 0.0) for name, stats in summary.items()}
                selected_engine, auto_order = _pick_auto_engine(
                    len(clean_text),
                    TextValidator.estimate_duration(clean_text),
                    auto_engine_pool,
                    telemetry_speeds=telemetry_speeds,
                )
                attempted_auto.add(selected_engine)
                active_config, tts_engine = auto_engine_pool[selected_engine]
                job["events"].append(f"⚡ AUTO: usando {selected_engine.upper()} para este capítulo")
                est = TextValidator.estimate_duration(clean_text)
                if est <= 0:
                    est = max(len(clean_text) / 15.0, 30.0)
                job["events"].append(f"   ↳ Texto: {len(clean_text)} chars, estimado {int(est)}s")
            estimated_seconds = TextValidator.estimate_duration(clean_text)
            if estimated_seconds <= 0:
                estimated_seconds = max(len(clean_text) / 15.0, 30.0)

            # Use TTS engine
            while True:
                if job.get("cancelRequested"):
                    _finalize_cancel(job_id, job, f"🛑 Conversão cancelada durante o capítulo {chapter_name}")
                    return

                tts_path, needs_transcode = _resolve_tts_output(output_file, active_config.engine if active_config else config.engine)
                synth_started = time.time()
                last_stage_timestamp = synth_started
                try:
                    await tts_engine.synthesize_async(clean_text, tts_path)
                    last_stage_timestamp = time.time()
                except Exception as exc:
                    if auto_mode:
                        next_engine = _next_auto_engine(auto_order, attempted_auto, auto_engine_pool)
                        if next_engine:
                            attempted_auto.add(next_engine)
                            active_config, tts_engine = auto_engine_pool[next_engine]
                            job["events"].append(f"   ↳ AUTO: alternando para {next_engine.upper()} após erro ({exc})")
                            continue
                    if _switch_to_next_engine(f"Engine {active_config.engine if active_config else config.engine} falhou ({exc})"):
                        continue
                    _record_chapter_failure(job, tts_engine, chapter_name, exc, chapter_index=idx)
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
                                active_config, tts_engine = auto_engine_pool[next_engine]
                                job["events"].append(f"   ↳ AUTO: alternando para {next_engine.upper()} após falha na conversão WAV→MP3")
                                continue
                        if _switch_to_next_engine("Conversão WAV→MP3 falhou"):
                            continue
                        _record_chapter_failure(job, tts_engine, chapter_name, "falha ao converter WAV para MP3", chapter_index=idx)
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
                            active_config, tts_engine = auto_engine_pool[next_engine]
                            job["events"].append("   ↳ AUTO: áudio vazio; tentando outra engine")
                            continue
                    if _switch_to_next_engine("Áudio vazio ou inexistente"):
                        continue
                        _record_chapter_failure(job, tts_engine, chapter_name, "áudio não foi gerado pelo serviço de voz", chapter_index=idx)
                        return
                break
            engine_runtime = max((last_stage_timestamp - synth_started), 0.001)

            # Get duration using ffprobe (no pydub/audioop dependency)
            duration_seconds = await _get_audio_duration(output_file)
            chapter_elapsed = time.time() - chapter_clock_start

            job["events"].append(f"✅ Concluído: {output_file.name}")
            job["chaptersCompleted"] = idx
            _set_chapter_status(job, idx, "completed")
            job["_currentChapterIndex"] = None

            # Persist every chapter completion (important milestone)
            _persist_job(job_id, force=True)

            outputs.append(
                {
                    "name": output_file.name,
                    "url": f"/api/outputs/{job_id}/{output_file.name}",
                    "durationSeconds": round(duration_seconds, 2),
                    "sizeBytes": output_file.stat().st_size,
                }
            )
            if zip_open and output_file.exists():
                try:
                    zip_archive.write(output_file, arcname=output_file.name)
                except Exception:
                    pass

            try:
                telemetry.record_sample(
                    engine=(active_config.engine if active_config else config.engine),
                    voice=(active_config.voice if active_config else None),
                    chars=len(clean_text),
                    synth_seconds=engine_runtime or chapter_elapsed,
                    total_seconds=chapter_elapsed,
                    audio_seconds=duration_seconds,
                    job_id=job_id,
                    chapter=chapter_name,
                )
                if engine_runtime:
                    chars_per_second = len(clean_text) / max(engine_runtime, 0.001)
                    job["events"].append(f"⏱️ {active_config.engine.upper()} ≈ {chars_per_second:.1f} chars/s")
            except Exception:
                pass

        job["_currentChapterIndex"] = None

        if zip_open:
            with contextlib.suppress(Exception):
                zip_archive.close()
            zip_open = False

        # Upload to R2 if configured
        if storage.is_enabled():
            job["events"].append("")
            job["events"].append("☁️ Enviando arquivos para storage permanente...")

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
                        job["events"].append(f"  ✅ {asset['name']} → R2")
                    else:
                        job["events"].append(f"  ⚠️ {asset['name']} → fallback local")
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
                job["events"].append(f"  ✅ {zip_file.name} → R2")
            else:
                zip_url = f"/api/outputs/{job_id}/{zip_file.name}"
                job["events"].append(f"  ⚠️ {zip_file.name} → fallback local")

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
                        job["events"].append("  ✅ Capa → R2")
                    else:
                        job["events"].append("  ⚠️ Capa → fallback local")
        else:
            # R2 not configured - use local URLs
            job["events"].append("")
            job["events"].append("ℹ️ R2 não configurado - arquivos salvos localmente")
            job["events"].append("⚠️ Arquivos serão perdidos após restart do servidor")
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
            outputs.insert(
                0,
                {
                    "name": log_path.name,
                    "url": f"/api/outputs/{job_id}/{log_path.name}",
                    "sizeBytes": log_path.stat().st_size,
                },
            )
            if zip_open:
                try:
                    zip_archive.write(log_path, arcname=log_path.name)
                except Exception:
                    pass

        job["state"] = "finished"
        job["progressPercent"] = 100
        job["outputs"] = outputs
        job["events"].append("")
        job["events"].append("✅ Conversão finalizada com sucesso")
        job["events"].append(f"📁 Arquivo disponível: {zip_file.name} ({len(chapters)} capítulos)")
        _persist_job(job_id)

        # Delete job state after successful completion (keep for failed jobs)
        job_manager.delete_job(job_id)

    except Exception as exc:  # pragma: no cover - defensive handling
        job["state"] = "failed"
        job["error"] = str(exc)
        job["events"].append(f"❌ Erro: {exc}")
        _persist_job(job_id)
        _persist_job_log(job_id, job)

    finally:
        with contextlib.suppress(Exception):
            if zip_archive:
                zip_archive.close()
        temp_path = Path(job["file_path"])
        if temp_path.exists():
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


def _set_chapter_status(job: dict, chapter_index: Optional[int], status: str) -> None:
    entries = job.get("chapterProgress")
    if not entries or chapter_index is None:
        return
    if isinstance(entries, list):
        idx = max(0, int(chapter_index) - 1)
        if idx < len(entries):
            entry = entries[idx]
            if isinstance(entry, dict):
                entry["status"] = status

def _record_chapter_failure(job: dict, tts_engine, chapter_name: str, error: object, chapter_index: Optional[int] = None) -> None:
    _set_chapter_status(job, chapter_index, "failed")
    last_error = getattr(tts_engine, "last_error", None)
    error_message = str(error) if error else "erro desconhecido"
    if isinstance(error, FileNotFoundError):
        failure_detail = last_error or "Edge TTS não criou o arquivo de áudio"
    else:
        failure_detail = last_error or error_message
    job["events"].append("")
    job["events"].append(f"❌ Falha na síntese do capítulo '{chapter_name}': {failure_detail}")
    if error:
        error_type = getattr(error, "__class__", type(error)).__name__
    else:
        error_type = "UnknownError"

    if last_error and error_message and last_error != error_message:
        job["events"].append(f"   ↳ Erro interno ({error_type}): {error_message}")
    elif not last_error and error_message:
        job["events"].append(f"   ↳ Erro interno ({error_type}): {error_message}")
    job["state"] = "failed"
    job["error"] = f"Falha na síntese do capítulo '{chapter_name}': {failure_detail}"
    job.setdefault("outputs", [])

    job_id = job.get("jobId")
    if job_id:
        _cleanup_job_output(job_id)
        _persist_job_log(job_id, job)

    _clear_job_cache(job)


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


if __name__ == "__main__":  # pragma: no cover - manual execution helper
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
