from uuid import uuid4

from fastapi.testclient import TestClient

from python_app import server
from python_app.src.progressive_playback_observation import ProgressivePlaybackObservationStore


def test_job_stream_records_client_journey_id_without_exposing_book_content(monkeypatch) -> None:
    job_id = str(uuid4())
    journey_id = str(uuid4())
    monkeypatch.setattr(
        server,
        "progressive_playback_observations",
        ProgressivePlaybackObservationStore(clock=lambda: 10),
    )
    monkeypatch.setitem(server.jobs, job_id, {"jobId": job_id, "state": "finished"})

    response = TestClient(server.app).get(f"/api/jobs/{job_id}/stream?journey_id={journey_id}")

    assert response.status_code == 200
    assert server.progressive_playback_observations.snapshot() == [
        {
            "jobId": job_id,
            "journeyId": journey_id,
            "transition": "stream_connected",
            "elapsedNanoseconds": 0,
        }
    ]
