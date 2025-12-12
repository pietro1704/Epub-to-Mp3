from __future__ import annotations

import asyncio
import shutil
from pathlib import Path
from uuid import uuid4
from unittest.mock import patch, AsyncMock

import pytest

from python_app import server

FIXTURE_BOOK = Path(__file__).resolve().parents[2] / "web" / "public" / "sample.epub"

requires_ffmpeg = pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg não encontrado")


@requires_ffmpeg
def test_process_conversion_generates_chapters(tmp_path, monkeypatch):
    """Test server conversion with mocked TTS engine."""
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

    # Mock the TTS engine to create dummy audio files
    async def mock_synthesize(self, text, output_path):
        output_path = Path(output_path)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        # Create a minimal valid MP3 file (ID3 header + silence)
        # This is a minimal MP3 frame that ffprobe can read
        mp3_header = bytes([
            0xFF, 0xFB, 0x90, 0x00,  # MP3 frame header
        ] + [0x00] * 417)  # Padding to make valid frame
        output_path.write_bytes(mp3_header * 10)  # Multiple frames
        return output_path

    with patch('src.tts.edge_engine.EdgeTTSEngine.synthesize_async', mock_synthesize):
        asyncio.run(server.process_conversion(job_id))

    job = server.jobs[job_id]
    assert job["state"] == "finished", f"Job failed: {job.get('error')}"
    assert len(job["outputs"]) >= 2  # At least zip + 1 chapter

    job_dir = tmp_path / job_id
    generated_files = {p.name for p in job_dir.iterdir() if p.is_file()}

    for asset in job["outputs"]:
        assert asset["name"] in generated_files
        file_path = job_dir / asset["name"]
        assert file_path.stat().st_size > 0

    # Confirm zip was created
    zip_name = job["outputs"][0]["name"]
    assert zip_name.endswith(".zip")

    server.jobs.pop(job_id, None)
