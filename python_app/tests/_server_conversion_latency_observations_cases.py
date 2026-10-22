"""Latency Observations regression scenarios, collected by test_server_conversion."""

from __future__ import annotations

from python_app.tests._server_conversion_test_support import (
    TestClient as TestClient,
    _configure_server_paths as _configure_server_paths,
    _make_telemetry as _make_telemetry,
    server as server,
)

def test_journey_observations_keep_only_redacted_timing_boundaries(tmp_path, monkeypatch):
    _configure_server_paths(tmp_path, monkeypatch)
    _make_telemetry(tmp_path, monkeypatch)
    job_id = "journey-job"
    server.jobs[job_id] = {"jobId": job_id, "state": "running", "events": []}
    client = TestClient(server.app)

    response = client.post(
        f"/api/jobs/{job_id}/journey-observations",
        json={
            "journeyId": "123e4567-e89b-12d3-a456-426614174000",
            "transition": "audio_audible",
            "elapsedNanoseconds": 42,
        },
    )

    assert response.status_code == 200
    assert response.json() == {"status": "recorded"}
    assert server.jobs[job_id]["journeyObservations"] == [
        {
            "journeyId": "123e4567-e89b-12d3-a456-426614174000",
            "transition": "audio_audible",
            "elapsedNanoseconds": 42,
            "recordedAt": server.jobs[job_id]["journeyObservations"][0]["recordedAt"],
        }
    ]
    server.jobs.pop(job_id, None)


def test_journey_observations_correlate_playback_delay_and_cancelled_seek(tmp_path, monkeypatch):
    _configure_server_paths(tmp_path, monkeypatch)
    _make_telemetry(tmp_path, monkeypatch)
    job_id = "journey-sequence"
    server.jobs[job_id] = {"jobId": job_id, "state": "running", "events": []}
    client = TestClient(server.app)

    playback_id = "123e4567-e89b-12d3-a456-426614174001"
    seek_id = "123e4567-e89b-12d3-a456-426614174002"
    for journey_id, transition, elapsed in [
        (playback_id, "play_requested", 0),
        (playback_id, "audio_queued", 1_000_000_000),
        (playback_id, "audio_audible", 1_500_000_000),
        (seek_id, "seek_requested", 0),
        (seek_id, "cancelled", 250_000_000),
    ]:
        response = client.post(
            f"/api/jobs/{job_id}/journey-observations",
            json={
                "journeyId": journey_id,
                "transition": transition,
                "elapsedNanoseconds": elapsed,
            },
        )
        assert response.status_code == 200

    records = server.jobs[job_id]["journeyObservations"]
    assert [(record["journeyId"], record["transition"], record["elapsedNanoseconds"])
            for record in records] == [
        (playback_id, "play_requested", 0),
        (playback_id, "audio_queued", 1_000_000_000),
        (playback_id, "audio_audible", 1_500_000_000),
        (seek_id, "seek_requested", 0),
        (seek_id, "cancelled", 250_000_000),
    ]
    assert all(set(record) == {"journeyId", "transition", "elapsedNanoseconds", "recordedAt"}
               for record in records)
    server.jobs.pop(job_id, None)


def test_journey_observations_reject_untrusted_metadata(tmp_path, monkeypatch):
    _configure_server_paths(tmp_path, monkeypatch)
    _make_telemetry(tmp_path, monkeypatch)
    job_id = "journey-invalid"
    server.jobs[job_id] = {"jobId": job_id, "state": "running", "events": []}
    client = TestClient(server.app)

    response = client.post(
        f"/api/jobs/{job_id}/journey-observations",
        json={
            "journeyId": "not-a-uuid",
            "transition": "book_title_leak",
            "elapsedNanoseconds": 0,
            "title": "must be ignored",
        },
    )

    assert response.status_code == 422
    assert "journeyObservations" not in server.jobs[job_id]
    server.jobs.pop(job_id, None)
