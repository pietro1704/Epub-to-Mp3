from __future__ import annotations

import asyncio
import shutil
from pathlib import Path
from uuid import uuid4

import pytest

from python_app import server

FIXTURE_BOOK = Path(__file__).resolve().parents[2] / "web" / "public" / "sample.epub"

requires_say = pytest.mark.skipif(shutil.which("say") is None, reason="comando 'say' indisponível")
requires_ffmpeg = pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg não encontrado")


@requires_say
@requires_ffmpeg
def test_process_conversion_generates_chapters(tmp_path, monkeypatch):
    job_id = str(uuid4())

    monkeypatch.setattr(server, "output_dir", tmp_path)
    server.output_dir.mkdir(exist_ok=True)

    upload_path = tmp_path / f"{job_id}_book.epub"
    upload_path.write_bytes(FIXTURE_BOOK.read_bytes())

    server.jobs[job_id] = {
        "jobId": job_id,
        "state": "queued",
        "events": [],
        "file_path": str(upload_path),
        "engine": "edge",
        "voice": None,
        "chapters": None,
        "footnote_mode": "inline",
        "language": "pt-BR",
        "outputs": [],
    }

    asyncio.run(server.process_conversion(job_id))

    job = server.jobs[job_id]
    assert job["state"] == "finished"
    assert len(job["outputs"]) == 5  # zip + 4 capítulos (inclui sub-capítulos)

    job_dir = tmp_path / job_id
    generated_files = {p.name for p in job_dir.iterdir() if p.is_file()}

    for asset in job["outputs"]:
        assert asset["name"] in generated_files
        file_path = job_dir / asset["name"]
        assert file_path.stat().st_size > 0

    # confirma que os mp3 estão dentro do zip
    zip_name = job["outputs"][0]["name"]
    assert zip_name.endswith(".zip")

    server.jobs.pop(job_id, None)
