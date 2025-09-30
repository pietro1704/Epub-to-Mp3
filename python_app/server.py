#!/usr/bin/env python3
"""FastAPI server for converting EPUBs into spoken MP3 chapters."""

from __future__ import annotations

import asyncio
import uuid
import zipfile
from pathlib import Path
from typing import Dict, Optional

from fastapi import BackgroundTasks, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from pydantic import BaseModel
from pydub import AudioSegment

from src.config import ConversionConfig
from src.ebook_reader import EbookReader
from src.tts.factory import TTSFactory

app = FastAPI(title="EPUB to MP3 Converter API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173", "http://localhost:3000"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

jobs: Dict[str, dict] = {}
output_dir = Path("output")
output_dir.mkdir(exist_ok=True)

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
    job_id = str(uuid.uuid4())
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
        chapters = reader.get_chapters()

        job["events"].append(f"📜 Título: {title}")
        job["events"].append(f"✍️ Autor: {author}")
        job["events"].append(f"📊 Capítulos: {len(chapters)}")
        job["chaptersTotal"] = len(chapters)
        job["chaptersCompleted"] = 0

        job["events"].append("")
        job["events"].append("🌐 DETECÇÃO DE IDIOMA")
        job["events"].append("-" * 64)
        detected_lang = job.get("language") or "pt-BR"
        job["detectedLanguage"] = detected_lang
        job["events"].append(f"🌐 Idioma principal: {detected_lang} (estimado)")

        # Create TTS engine using factory
        config = ConversionConfig(
            engine=job.get("engine", "edge"),
            voice=job.get("voice"),
            primary_language=detected_lang,
            output_dir=str(output_dir / job_id),
        )

        tts_engine = tts_factory.create_engine(config)

        job["events"].append("")
        job["events"].append(f"🎙️ Engine: {config.engine}")
        job["events"].append(f"🗣️ Voz: {config.voice or 'padrão'}")

        job_output_dir = output_dir / job_id
        job_output_dir.mkdir(exist_ok=True)

        outputs = []

        for idx, chapter in enumerate(chapters, 1):
            chapter_name = getattr(chapter, "name", f"Chapter {idx}")
            job["currentChapter"] = chapter_name
            job["events"].append("")
            job["events"].append(f"🎯 Convertendo capítulo {idx}/{len(chapters)}: {chapter_name}")

            progress = (idx / len(chapters)) * 100 if chapters else 100
            job["progressPercent"] = progress

            output_file = job_output_dir / f"{idx:03d} - {sanitize_filename(chapter_name)}.mp3"
            chapter_text = getattr(chapter, "speech_text", None) or chapter.text or ""

            # Use TTS engine
            await tts_engine.synthesize_async(chapter_text, output_file)

            # Get duration
            audio = AudioSegment.from_file(output_file)
            duration_seconds = audio.duration_seconds

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

        zip_file = job_output_dir / f"{sanitize_filename(title)}.zip"
        with zipfile.ZipFile(zip_file, "w") as archive:
            for asset in outputs:
                path = job_output_dir / asset["name"]
                if path.exists():
                    archive.write(path, arcname=asset["name"])

        outputs.insert(
            0,
            {
                "name": zip_file.name,
                "url": f"/api/outputs/{job_id}/{zip_file.name}",
                "sizeBytes": zip_file.stat().st_size,
            },
        )

        job["state"] = "finished"
        job["progressPercent"] = 100
        job["outputs"] = outputs
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


def sanitize_filename(name: str) -> str:
    sanitized = name.replace("/", "_").replace("\\", "_")
    sanitized = sanitized.replace(":", "_").replace("*", "_")
    sanitized = sanitized.replace("?", "_").replace('"', "_")
    sanitized = sanitized.replace("<", "_").replace(">", "_")
    sanitized = sanitized.replace("|", "_")
    return sanitized.strip()


if __name__ == "__main__":  # pragma: no cover - manual execution helper
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
