"""Ephemeral server-side HTTP correlation, never a claim of client receipt."""

from __future__ import annotations

import asyncio
import threading
import time
import uuid
from collections import OrderedDict
from typing import Callable

from starlette.responses import FileResponse, Response


def validate_journey_id(value: str) -> str:
    """Accept only a UUID in hyphenated form, without arbitrary header metadata."""
    try:
        canonical = str(uuid.UUID(value))
    except (ValueError, AttributeError, TypeError):
        raise ValueError("Invalid playback journey ID") from None
    if canonical != value.lower():
        raise ValueError("Invalid playback journey ID")
    return canonical


class StreamHTTPObservationStore:
    """Globally bounded local records; expired or evicted requests cannot return."""

    def __init__(self, *, clock: Callable[[], int] = time.monotonic_ns):
        self._clock = clock
        self._lock = threading.Lock()
        self._records: OrderedDict[str, tuple[int, dict]] = OrderedDict()

    def _prune(self, now: int) -> None:
        # Handler receipt can precede insertion, so expiry cannot assume that
        # concurrent requests entered the store in clock order.
        for request_id, (started, _) in list(self._records.items()):
            if now - started >= 300_000_000_000:
                del self._records[request_id]

    def received_at(self) -> int:
        """Capture the handler boundary using this store's server clock."""
        return self._clock()

    def begin(self, journey_id: str, publication_id: str, *, received_at: int | None = None) -> str:
        journey_id = validate_journey_id(journey_id)
        request_id = str(uuid.uuid4())
        with self._lock:
            now = self._clock()
            self._prune(now)
            self._records[request_id] = (now if received_at is None else received_at, {
                "version": 1,
                "requestId": request_id,
                "journeyId": journey_id,
                "publicationId": publication_id,
                "requestReceivedElapsedNanoseconds": 0,
                "outcome": "pending",
            })
            while len(self._records) > 200:
                self._records.popitem(last=False)
        return request_id

    def finish(self, request_id: str, *, outcome: str, status: int | None, byte_count: int) -> None:
        with self._lock:
            now = self._clock()
            self._prune(now)
            entry = self._records.get(request_id)
            if entry is None or entry[1]["outcome"] != "pending":
                return
            started, record = entry
            record.update({
                "outcome": outcome,
                "responseBytes": byte_count,
                "responseCompletedElapsedNanoseconds": max(0, now - started),
            })
            if status is not None:
                record["responseStatus"] = status

    def export(self) -> list[dict]:
        """Return a local snapshot; this is not exposed as an HTTP endpoint."""
        with self._lock:
            self._prune(self._clock())
            return [dict(record) for _, record in self._records.values()]


class ObservedFileResponse(Response):
    """Observe successful ASGI sends while preserving FileResponse range behavior.

    A body send acknowledges only the ASGI transport boundary, not network
    receipt or playback. Path-send delegation does not acknowledge file bytes.
    """

    def __init__(self, response: FileResponse, store: StreamHTTPObservationStore,
                 journey_id: str, publication_id: str, *, received_at: int | None = None):
        self._response = response
        self._store = store
        journey_id = validate_journey_id(journey_id)
        self._request_id = store.begin(journey_id, publication_id, received_at=received_at)
        super().__init__(status_code=response.status_code, headers=dict(response.headers))
        # Do not inject Response's empty-body content-length into FileResponse.
        self.raw_headers = response.raw_headers
        self.headers["X-Playback-Journey-ID"] = journey_id
        self.headers["X-Stream-Request-ID"] = self._request_id
        self.headers["X-Stream-Publication-ID"] = publication_id
        self.headers["Cache-Control"] = "no-store"
        self._correlation_headers = [
            (name.lower().encode("ascii"), self.headers[name].encode("ascii"))
            for name in ("X-Playback-Journey-ID", "X-Stream-Request-ID", "X-Stream-Publication-ID",
                         "Cache-Control")
        ]

    async def __call__(self, scope, receive, send) -> None:
        status = None
        byte_count = 0
        outcome = "failed"
        finished = False

        def finish(result: str) -> None:
            nonlocal finished
            if not finished:
                self._store.finish(self._request_id, outcome=result, status=status, byte_count=byte_count)
                finished = True

        async def observed_send(message):
            nonlocal status, byte_count, outcome
            if message["type"] == "http.response.start":
                # FileResponse may generate a separate error response for an
                # invalid range; correlate that response too, without success.
                # Every correlated response must forbid caching ephemeral IDs,
                # including error responses and files with a prior cache policy.
                names = {name for name, _ in self._correlation_headers}
                message = {**message, "headers": [
                    (name, value) for name, value in message.get("headers", [])
                    if name.lower() not in names
                ] + self._correlation_headers}
            await send(message)
            if message["type"] == "http.response.start":
                status = message["status"]
            elif message["type"] == "http.response.pathsend":
                outcome = "delegated_pathsend"
                finish(outcome)
            elif message["type"] == "http.response.body":
                byte_count += len(message.get("body", b""))
                if not message.get("more_body", False):
                    if status is None or status >= 400:
                        outcome = "failed"
                    elif scope.get("method") == "HEAD":
                        outcome = "headers_only"
                    elif status == 206:
                        outcome = "partial_body_sent"
                    else:
                        outcome = "body_sent"
                    finish(outcome)

        try:
            await self._response(scope, receive, observed_send)
        except asyncio.CancelledError:
            finish("cancelled")
            raise
        except Exception:
            finish("failed")
            raise
        finally:
            finish(outcome)
        if self.background is not None:
            await self.background()


stream_http_observations = StreamHTTPObservationStore()
