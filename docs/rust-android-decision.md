# Rust-to-Android transport decision

**Status:** accepted for Phase 5 Task 5.3 (2026-09-27)

## Decision

Flutter/Android continues to use the Rust conversion server through its HTTP API. The Android client does not embed a second Rust conversion pipeline and does not add an offline FFI bridge.

The client uses the existing `ApiClient` Dio wrapper and the same contract as the other remote clients:

- `POST /api/uploads` with multipart `file`.
- `POST /api/convert` with multipart `upload_id`, `engine`, and optional conversion fields.
- `GET /api/jobs/{id}` for snapshots.
- `GET /api/jobs/{id}/stream` for long-lived SSE snapshots.
- `GET /api/jobs/{id}/fulltext` for reader text.
- `GET /api/outputs/{id}/{filename}` (via returned URLs) for audio and archive assets.
- `GET /api/sessions?last=...` for legacy session history.

The Rust server must preserve the HTTP wire shapes already consumed by Flutter. `JobSnapshot` and `EbookFulltext` use camelCase JSON keys; `SessionRecord` remains snake_case because it represents the legacy session log. Unknown additive fields are safe for the generated Dart models, but renaming or removing existing fields is not.

## Android connectivity

The default Android emulator backend is `http://10.0.2.2:8000`, which maps to the development host. Physical devices and production builds must provide a reachable backend URL through app settings or deployment configuration. Cleartext HTTP is appropriate only for local development; production deployments should use HTTPS.

The SSE endpoint is intentionally not given a finite receive timeout. Flutter accepts `data:` JSON frames, ignores `event:` labels and heartbeat comments, and stops after the server sends a terminal snapshot (`finished`, `failed`, `interrupted`, or `cancelled`) and closes the stream.

## Deferred offline conversion

Offline conversion through Rust FFI is explicitly deferred. It would duplicate server orchestration, cache ownership, model management, storage policy, and job lifecycle behavior inside Android. It is not required by the current product contract. If offline conversion becomes a product requirement, it must be designed as a separate decision with explicit lifecycle, storage, model, and compatibility contracts rather than added as an Android-only shortcut.

## Compatibility guardrails

Contract changes should update the Flutter model/API tests and the Rust HTTP contract together. Before release validation, exercise at least one real Android/emulator flow against the Rust server: upload, submit, observe SSE, fetch fulltext, and download an output. This task intentionally does not run Flutter, Rust, build, or integration validation.
