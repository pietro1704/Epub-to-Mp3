# ADR: Cross-platform reactive state and Edge-first conversion

Date: 2026-10-02
Status: Accepted

## Context

Playback surfaces were able to observe different sources directly: the Flutter
player, AudioService callbacks, persisted widget state, job/SSE state, and local
component fields. This allowed stale callbacks to leave mini and expanded
players showing the wrong play/pause state or chapter. Mobile conversion also
must remain Edge-first; Piper is an explicit local fallback and must not be
loaded on unsupported Android APIs.

## Decision

Use a central playback coordinator per process. It owns reconciliation with the
real player and publishes an immutable snapshot with a monotonic revision.
Every UI, background service, widget, notification, external control, reader,
and conversion surface consumes the snapshot or a contract-compatible job
snapshot. UI emits commands only; commands are serialized and confirmed by the
real source before the snapshot changes.

Rust remains the shared authority for cross-platform domain rules and versioned
contracts. Flutter/Android, UIKit/AppKit, CLI, and backend adapters must align
with the contract rather than maintaining independent playback state.

Conversion policy is Edge-first when online and enabled. An explicitly
installed, compatible local model is a fallback only. Piper must never be the
implicit default and its native runtime must remain guarded on unsupported
Android APIs, including API 28.

Persist only rehydratable state. On relaunch, transient states are marked for
recovery and reconciled with the real player/converter before publication.
Existing installations may reset derived state automatically while preserving
books, audio, manifests, and conversion artifacts.

## Consequences

- Mini and expanded players cannot diverge from the central snapshot.
- Delayed callbacks can be discarded by session/revision ordering.
- Background Android playback remains the owner of the real player.
- The same state semantics must be implemented by every supported client.
- Android API 28 requires a real Edge transport path or a controlled
  unavailable state; removing the Piper guard is not an acceptable workaround.
- Acceptance requires reducer/contract tests, integration coverage, and a real
  Android-device matrix.

## Verification

The first implementation slice adds the Flutter playback coordinator and
snapshot tests. Remaining adapters must be migrated and verified before the
initiative is considered complete.
