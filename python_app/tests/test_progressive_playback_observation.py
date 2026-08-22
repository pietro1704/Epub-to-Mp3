from python_app.src.progressive_playback_observation import ProgressivePlaybackObservationStore


def test_store_records_monotonic_private_server_boundaries() -> None:
    now = 100
    store = ProgressivePlaybackObservationStore(clock=lambda: now)

    store.record(job_id="job-123", journey_id="journey-456", transition="stream_connected")
    now = 140
    store.record(job_id="job-123", journey_id="journey-456", transition="segment_available")

    assert store.snapshot() == [
        {
            "jobId": "job-123",
            "journeyId": "journey-456",
            "transition": "stream_connected",
            "elapsedNanoseconds": 0,
        },
        {
            "jobId": "job-123",
            "journeyId": "journey-456",
            "transition": "segment_available",
            "elapsedNanoseconds": 40,
        },
    ]


def test_store_keeps_elapsed_time_independent_per_journey() -> None:
    now = 100
    store = ProgressivePlaybackObservationStore(clock=lambda: now)

    store.record(job_id="job-a", journey_id="journey-a", transition="stream_connected")
    now = 140
    store.record(job_id="job-b", journey_id="journey-b", transition="stream_connected")
    now = 180
    store.record(job_id="job-b", journey_id="journey-b", transition="segment_available")
    now = 110
    store.record(job_id="job-a", journey_id="journey-a", transition="segment_available")

    assert store.snapshot()[-1]["elapsedNanoseconds"] == 10


def test_store_records_segment_for_each_connected_journey_of_a_job() -> None:
    store = ProgressivePlaybackObservationStore(clock=lambda: 100)
    store.record(job_id="job", journey_id="one", transition="stream_connected")
    store.record(job_id="job", journey_id="two", transition="stream_connected")

    store.record_for_job(job_id="job", transition="segment_available")

    assert [(record["journeyId"], record["transition"]) for record in store.snapshot()] == [
        ("one", "stream_connected"),
        ("two", "stream_connected"),
        ("one", "segment_available"),
        ("two", "segment_available"),
    ]
