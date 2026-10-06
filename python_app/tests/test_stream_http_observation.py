"""Runtime checks for bounded, server-clock-only HTTP observations."""

import asyncio
from uuid import uuid4

import pytest
from src.stream_http_observation import (
    ObservedFileResponse,
    StreamHTTPObservationStore,
    validate_journey_id,
)
from starlette.responses import FileResponse


def scope(*, headers=(), extensions=None, method="GET"):
    return {"type": "http", "method": method, "headers": list(headers),
            "extensions": extensions or {}}


async def receive():
    return {"type": "http.request", "body": b"", "more_body": False}


def response_for(tmp_path, store):
    audio = tmp_path / "audio.mp3"
    audio.write_bytes(b"actual audio bytes")
    return ObservedFileResponse(FileResponse(audio), store, str(uuid4()), str(uuid4()))


@pytest.mark.asyncio
async def test_last_body_is_not_complete_until_send_returns(tmp_path):
    store = StreamHTTPObservationStore()
    response = response_for(tmp_path, store)
    entered = asyncio.Event()
    release = asyncio.Event()
    bodies = []

    async def send(message):
        if message["type"] == "http.response.body":
            bodies.append(message["body"])
            entered.set()
            await release.wait()

    task = asyncio.create_task(response(scope(), receive, send))
    await asyncio.wait_for(entered.wait(), 2)
    assert store.export()[0]["outcome"] == "pending"
    release.set()
    await asyncio.wait_for(task, 2)
    record = store.export()[0]
    assert record["outcome"] == "body_sent"
    assert record["responseBytes"] == len(b"actual audio bytes")
    assert b"".join(bodies) == b"actual audio bytes"
    assert record["responseCompletedElapsedNanoseconds"] >= 0


@pytest.mark.asyncio
@pytest.mark.parametrize("cancel", [False, True])
async def test_failed_or_cancelled_send_never_claims_body_sent(tmp_path, cancel):
    store = StreamHTTPObservationStore()
    response = response_for(tmp_path, store)

    async def send(message):
        if message["type"] == "http.response.body":
            if cancel:
                raise asyncio.CancelledError()
            raise OSError("transport failed")

    with pytest.raises(asyncio.CancelledError if cancel else OSError):
        await response(scope(), receive, send)
    record = store.export()[0]
    assert record["outcome"] == ("cancelled" if cancel else "failed")
    assert record["responseBytes"] == 0
    assert "transport failed" not in str(record)


@pytest.mark.asyncio
@pytest.mark.parametrize("mode,expected", [
    ("range", "partial_body_sent"), ("pathsend", "delegated_pathsend"),
    ("head", "headers_only"), ("invalid_range", "failed"),
])
async def test_non_full_responses_are_not_full_audio_delivery(tmp_path, mode, expected):
    store = StreamHTTPObservationStore()
    response = response_for(tmp_path, store)
    messages = []

    async def send(message):
        messages.append(message)

    request = scope(
        headers=[(b"range", b"bytes=1-3")] if mode == "range" else
        [(b"range", b"bytes=999-1000")] if mode == "invalid_range" else (),
        extensions={"http.response.pathsend": {}} if mode == "pathsend" else None,
        method="HEAD" if mode == "head" else "GET",
    )
    await response(request, receive, send)
    record = store.export()[0]
    assert record["outcome"] == expected
    start = next(message for message in messages if message["type"] == "http.response.start")
    assert dict(start["headers"])[b"x-stream-request-id"].decode() == record["requestId"]
    if mode == "range":
        assert record["responseStatus"] == 206
        assert record["responseBytes"] == 3
        assert b"".join(item.get("body", b"") for item in messages) == b"ctu"
    if mode == "pathsend":
        assert record["responseBytes"] == 0


def test_capacity_expiry_and_export_isolation(tmp_path):
    now = [0]
    store = StreamHTTPObservationStore(clock=lambda: now[0])
    for _ in range(201):
        response_for(tmp_path, store)
    records = store.export()
    assert len(records) == 200
    assert len({record["requestId"] for record in records}) == 200
    records[0]["outcome"] = "invented"
    assert store.export()[0]["outcome"] == "pending"
    now[0] = 300_000_000_000
    assert store.export() == []


@pytest.mark.parametrize("value", ["", "not-uuid", " " + str(uuid4()), str(uuid4()).replace("-", ""),
                                    "{" + str(uuid4()) + "}"])
def test_header_requires_strict_uuid(value):
    with pytest.raises(ValueError):
        validate_journey_id(value)


def test_header_accepts_canonical_uuid():
    value = str(uuid4())
    assert validate_journey_id(value.upper()) == value


@pytest.mark.asyncio
@pytest.mark.parametrize("range_value,status,expected_bytes,content_range", [
    (None, 200, b"actual audio bytes", None),
    (b"bytes=1-3", 206, b"ctu", b"bytes 1-3/18"),
    (b"bytes=999-1000", 416, b"", b"bytes */18"),
])
@pytest.mark.parametrize("existing_policy", [None, "public, max-age=3600"])
async def test_correlated_responses_cannot_cache_journey_headers(
    tmp_path, range_value, status, expected_bytes, content_range, existing_policy
):
    audio = tmp_path / "audio.mp3"
    audio.write_bytes(b"actual audio bytes")
    original = FileResponse(audio, headers={"Cache-Control": existing_policy} if existing_policy else None)
    response = ObservedFileResponse(original, StreamHTTPObservationStore(), str(uuid4()), str(uuid4()))
    messages = []

    async def send(message):
        messages.append(message)

    await response(scope(headers=[(b"range", range_value)] if range_value else ()), receive, send)
    start = next(message for message in messages if message["type"] == "http.response.start")
    headers = dict(start["headers"])
    assert start["status"] == status
    assert b"".join(message.get("body", b"") for message in messages) == expected_bytes
    assert headers.get(b"content-range") == content_range
    assert [value for name, value in start["headers"] if name.lower() == b"cache-control"] == [b"no-store"]
    assert headers[b"x-stream-request-id"].decode() == response.headers["X-Stream-Request-ID"]


@pytest.mark.asyncio
async def test_concurrent_requests_keep_independent_cancel_and_completion(tmp_path):
    store = StreamHTTPObservationStore()
    blocked = response_for(tmp_path, store)
    successful = response_for(tmp_path, store)
    entered = asyncio.Event()

    async def blocked_send(message):
        if message["type"] == "http.response.body":
            entered.set()
            await asyncio.Event().wait()

    async def successful_send(message):
        return None

    task = asyncio.create_task(blocked(scope(), receive, blocked_send))
    await asyncio.wait_for(entered.wait(), 2)
    try:
        await successful(scope(), receive, successful_send)
    finally:
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
    records = {record["requestId"]: record for record in store.export()}
    assert records[blocked.headers["X-Stream-Request-ID"]]["outcome"] == "cancelled"
    assert records[successful.headers["X-Stream-Request-ID"]]["outcome"] == "body_sent"
    for response in (blocked, successful):
        record = records[response.headers["X-Stream-Request-ID"]]
        assert record["journeyId"] == response.headers["X-Playback-Journey-ID"]
        assert record["publicationId"] == response.headers["X-Stream-Publication-ID"]


def test_expired_and_evicted_late_completion_cannot_resurrect_records(tmp_path):
    now = [0]
    store = StreamHTTPObservationStore(clock=lambda: now[0])
    first = response_for(tmp_path, store)
    for _ in range(200):
        response_for(tmp_path, store)
    first_id = first.headers["X-Stream-Request-ID"]
    store.finish(first_id, outcome="body_sent", status=200, byte_count=10)
    assert first_id not in {record["requestId"] for record in store.export()}
    now[0] = 299_000_000_000
    newer = response_for(tmp_path, store)
    old_receipt = store.begin(str(uuid4()), str(uuid4()), received_at=0)
    now[0] = 300_000_000_000
    store.finish(old_receipt, outcome="body_sent", status=200, byte_count=10)
    assert [record["requestId"] for record in store.export()] == [newer.headers["X-Stream-Request-ID"]]
