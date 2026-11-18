# Edge transport reuse spike — 2026-07-23

Status: INVALIDATED

## Scope

Evaluate whether persistent Edge communicator/WebSocket reuse should be promoted before changing the current per-segment transport lifecycle.

## Verified locally

- `EdgeTTSEngine._synthesize_segment()` creates a new `edge_tts.Communicate(text, voice)` for each segment.
- The request acquires the global and per-instance rate-limiters through `AsyncExitStack`.
- Stream creation and asynchronous consumption happen inside that scoped request.
- Request cleanup, cancellation, and limiter release are coupled to the existing request scope.
- Existing `request_ms` telemetry covers the request lifecycle but does not independently split connection/handshake time from stream time.
- Existing unit tests cover successful streams, metric emission, callback failures, validation timing, and failure handling.

## Not verified

- No live Edge conversion was executed in this cycle.
- No controlled A/B comparison of communicator reuse versus the current lifecycle exists.
- No measured latency reduction or error-rate comparison supports a persistent session pool.

## Decision

Do not introduce a persistent WebSocket/session pool. The current transport remains unchanged. A future spike may be reopened only with an isolated benchmark that records at least:

- communicator/handshake latency;
- first-audio latency;
- total request latency;
- rate-limit, timeout, and no-audio rates;
- cleanup and cancellation behavior;
- identical text, voice, segment policy, and isolated output roots.

The adaptive segment-duration policy is independent of this result and remains behind `EDGE_ADAPTIVE_SEGMENT_SECONDS=0`.
