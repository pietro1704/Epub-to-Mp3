from pathlib import Path

import pytest
from fastapi.testclient import TestClient

import python_app.server as server_mod


@pytest.fixture()
def client(tmp_path: Path):
    original_output_dir = server_mod.output_dir
    original_job_manager = server_mod.job_manager
    original_jobs = dict(server_mod.jobs)
    server_mod.output_dir = tmp_path / "output"
    server_mod.output_dir.mkdir(parents=True, exist_ok=True)
    server_mod.job_manager = server_mod.JobManager(tmp_path / ".jobs")
    server_mod.jobs.clear()
    try:
        yield TestClient(server_mod.app)
    finally:
        server_mod.output_dir = original_output_dir
        server_mod.job_manager = original_job_manager
        server_mod.jobs.clear()
        server_mod.jobs.update(original_jobs)


def test_job_log_endpoint_serves_conversion_log_file(client: TestClient):
    job_id = "job-log-file"
    job_dir = server_mod.output_dir / "Test_Book"
    job_dir.mkdir(parents=True)
    log_path = job_dir / "conversion.log"
    log_path.write_text("first line\nsecond line\n", encoding="utf-8")
    server_mod.jobs[job_id] = {
        "jobId": job_id,
        "state": "finished",
        "bookTitle": "Test Book",
        "outputDir": str(job_dir),
    }

    response = client.get(f"/api/jobs/{job_id}/log")

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/plain")
    assert response.text == "first line\nsecond line\n"


def test_job_log_endpoint_falls_back_to_raw_log(client: TestClient):
    job_id = "job-raw-log"
    server_mod.jobs[job_id] = {
        "jobId": job_id,
        "state": "running",
        "bookTitle": "Test Book",
        "_raw_log": ["10:00:01 Starting", "10:00:02 Finished chapter 1"],
        "events": ["ignored event"],
    }

    response = client.get(f"/api/jobs/{job_id}/log")

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/plain")
    assert response.text == "10:00:01 Starting\n10:00:02 Finished chapter 1\n"


def test_job_log_endpoint_falls_back_to_events(client: TestClient):
    job_id = "job-events-log"
    server_mod.jobs[job_id] = {
        "jobId": job_id,
        "state": "running",
        "bookTitle": "Test Book",
        "events": ["✅ Loading book", "✅ Finished"],
    }

    response = client.get(f"/api/jobs/{job_id}/log")

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/plain")
    assert response.text == "Loading book\nFinished\n"


def test_job_log_endpoint_rejects_invalid_job_id(client: TestClient):
    response = client.get("/api/jobs/bad.job/log")

    assert response.status_code == 400
    assert response.json()["detail"] == "Invalid job id"


def test_job_log_endpoint_does_not_serve_symlink_outside_output(client: TestClient, tmp_path: Path):
    job_id = "job-symlink-log"
    job_dir = server_mod.output_dir / "Test_Book"
    job_dir.mkdir(parents=True)
    outside_log = tmp_path / "outside.log"
    outside_log.write_text("secret\n", encoding="utf-8")
    (job_dir / "conversion.log").symlink_to(outside_log)
    server_mod.jobs[job_id] = {
        "jobId": job_id,
        "state": "running",
        "bookTitle": "Test Book",
        "outputDir": str(job_dir),
        "_raw_log": ["safe fallback"],
    }

    response = client.get(f"/api/jobs/{job_id}/log")

    assert response.status_code == 200
    assert response.text == "safe fallback\n"
    assert "secret" not in response.text


def test_job_log_endpoint_returns_404_for_unknown_job(client: TestClient):
    response = client.get("/api/jobs/missing-job/log")

    assert response.status_code == 404
    assert response.json()["detail"] == "Job not found"


def test_job_log_endpoint_rejects_outputdir_escaping_root(client: TestClient, tmp_path: Path):
    """CodeQL alert #80 hardening: even if a job persisted an `outputDir`
    that resolves outside `output_dir`, the endpoint must refuse to serve
    the log instead of leaking files via path-traversal.
    """
    job_id = "job-escape-outputdir"
    outside_dir = tmp_path / "outside_root"
    outside_dir.mkdir(parents=True)
    (outside_dir / "conversion.log").write_text("secret\n", encoding="utf-8")
    server_mod.jobs[job_id] = {
        "jobId": job_id,
        "state": "finished",
        "bookTitle": "Test Book",
        "outputDir": str(outside_dir),
    }

    response = client.get(f"/api/jobs/{job_id}/log")

    # Either the endpoint returns 200 with non-leaked content (raw/events
    # fallback) or it explicitly errors. The only thing it must NOT do
    # is leak the outside file.
    assert "secret" not in response.text
