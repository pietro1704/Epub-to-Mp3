#!/usr/bin/env python3
"""FastAPI server for converting EPUBs into spoken MP3 chapters."""

from __future__ import annotations

import asyncio
import logging
import os
import shutil
import uuid
import zipfile
from pathlib import Path
import re
from typing import Dict, Optional

logger = logging.getLogger(__name__)

from fastapi import BackgroundTasks, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from pydantic import BaseModel

from src.config import ConversionConfig
from src.ebook_reader import EbookReader
from src.tts.factory import TTSFactory
from src.storage_manager import get_storage_manager
from src.utils import FileManager
from src.cache_manager import CacheManager
from src.paths import OUTPUT_DIR
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

jobs: Dict[str, dict] = {}
# Para deployments em cloud (HF Spaces, etc.), use /tmp; caso contrário, usa OUTPUT_DIR da raiz do projeto
# Se OUTPUT_DIR env var estiver definida, usa ela; senão usa OUTPUT_DIR do paths.py
if os.getenv("OUTPUT_DIR"):
    output_dir = Path(os.getenv("OUTPUT_DIR"))
elif os.getenv("SPACE_ID"):  # HuggingFace Spaces
    output_dir = Path("/tmp/output")
else:
    output_dir = OUTPUT_DIR

output_dir.mkdir(exist_ok=True, parents=True)

tts_factory = TTSFactory()


class JobStatus(BaseModel):
    jobId: str
    state: str
    events: list[str] = []
    detectedLanguage: Optional[str] = None
    chaptersTotal: Optional[int] = None
    chaptersCompleted: Optional[int] = None
    currentChapter: Optional[str] = None
    progressPercent: Optional[float] = None
    outputs: list[dict] = []
    error: Optional[str] = None


@app.post("/api/convert")
async def convert_ebook(
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
    engine: str = Form("edge"),
    voice: Optional[str] = Form(None),
    chapters: Optional[str] = Form(None),
    footnote_mode: Optional[str] = Form("inline"),
    language: Optional[str] = Form(None),
) -> dict[str, str]:
    job_id = f"{uuid.uuid4()}"
    temp_file = output_dir / f"{job_id}_{file.filename}"

    with temp_file.open("wb") as buffer:
        buffer.write(await file.read())

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
        "outputs": [],
    }

    background_tasks.add_task(process_conversion, job_id)
    return {"jobId": job_id}


@app.get("/api/jobs/{job_id}")
async def get_job_status(job_id: str) -> JobStatus:
    if job_id not in jobs:
        raise HTTPException(status_code=404, detail="Job not found")
    return JobStatus(**jobs[job_id])


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
        }
    }


async def process_conversion(job_id: str) -> None:
    job = jobs[job_id]

    try:
        job["state"] = "running"
        job["events"].append("📚 METADADOS DO EBOOK")
        job["events"].append("=" * 64)

        file_path = Path(job["file_path"])
        reader = EbookReader(str(file_path))

        title = reader.title or "Livro_Desconhecido"
        author = reader.author or "Autor Desconhecido"
        job["bookTitle"] = title

        job["events"].append(f"📜 Título: {title}")
        job["events"].append(f"✍️ Autor: {author}")
        job["chaptersCompleted"] = 0

        job["events"].append("")
        job["events"].append("🌐 DETECÇÃO DE IDIOMA")
        job["events"].append("-" * 64)
        detected_lang = job.get("language") or "pt-BR"
        job["detectedLanguage"] = detected_lang
        job["events"].append(f"🌐 Idioma principal: {detected_lang} (estimado)")

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
        )

        selector_text = job.get("chapters")
        chapters = _prepare_chapters(reader, config, selector_text)
        selection_note = " (filtro aplicado)" if selector_text else ""
        job["events"].append(f"📊 Capítulos: {len(chapters)}{selection_note}")
        job["chaptersTotal"] = len(chapters)

        tts_engine = tts_factory.create_engine(config)

        job["events"].append("")
        job["events"].append(f"🎙️ Engine: {config.engine}")
        job["events"].append(f"🗣️ Voz: {config.voice or 'padrão'}")

        job_output_dir = output_dir / job_id
        if job_output_dir.exists():
            shutil.rmtree(job_output_dir, ignore_errors=True)
        job_output_dir.mkdir(exist_ok=True)

        outputs = []

        for idx, chapter in enumerate(chapters, 1):
            chapter_name = getattr(chapter, "name", f"Chapter {idx}")
            job["currentChapter"] = chapter_name
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
                continue

            # Use TTS engine
            try:
                await tts_engine.synthesize_async(chapter_text, output_file)
            except FileNotFoundError as exc:
                _record_chapter_failure(job, tts_engine, chapter_name, exc)
                return
            except Exception as exc:
                _record_chapter_failure(job, tts_engine, chapter_name, exc)
                return

            if not output_file.exists() or output_file.stat().st_size == 0:
                _record_chapter_failure(job, tts_engine, chapter_name, "áudio não foi gerado pelo serviço de voz")
                return

            # Get duration using ffprobe (no pydub/audioop dependency)
            duration_seconds = await _get_audio_duration(output_file)

            job["events"].append(f"✅ Concluído: {output_file.name}")
            job["chaptersCompleted"] = idx

            outputs.append(
                {
                    "name": output_file.name,
                    "url": f"/api/outputs/{job_id}/{output_file.name}",
                    "durationSeconds": round(duration_seconds, 2),
                    "sizeBytes": output_file.stat().st_size,
                }
            )

        book_safe_name = FileManager.sanitize_filename(title)
        zip_file = job_output_dir / f"{book_safe_name}.zip"
        with zipfile.ZipFile(zip_file, "w") as archive:
            for asset in outputs:
                path = job_output_dir / asset["name"]
                if path.exists():
                    archive.write(path, arcname=asset["name"])

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

        job["state"] = "finished"
        job["progressPercent"] = 100
        job["outputs"] = outputs
        job["events"].append("")
        job["events"].append("✅ Conversão finalizada com sucesso")
        job["events"].append(f"📁 Arquivo disponível: {zip_file.name} ({len(chapters)} capítulos)")

    except Exception as exc:  # pragma: no cover - defensive handling
        job["state"] = "failed"
        job["error"] = str(exc)
        job["events"].append(f"❌ Erro: {exc}")

    finally:
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

def _record_chapter_failure(job: dict, tts_engine, chapter_name: str, error: object) -> None:
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
        try:
            job_dir = output_dir / job_id
            if job_dir.exists():
                shutil.rmtree(job_dir, ignore_errors=True)
        except Exception:
            pass

    # Clear cache and checkpoints related to this ebook to avoid stale data
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
        try:
            converter_app.language_profile = converter_app._prepare_language_profile(reader, structure_items, verbose=False)
            converter_app._apply_language_preferences(config)
        except PermissionError:
            # Cache directory not writable: skip language detection that needs .cache
            converter_app.language_profile = None
        except Exception:
            converter_app.language_profile = None
        transformed_items = converter_app._apply_text_transforms(structure_items, config, reader)
        converter_app._apply_structure_to_reader(reader, transformed_items)
        chapters = reader.get_chapter_structure(preserve_all=config.preserve_all_chapters)
        return chapters or reader.get_chapters()
    except Exception:
        return reader.get_chapters()


if __name__ == "__main__":  # pragma: no cover - manual execution helper
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
