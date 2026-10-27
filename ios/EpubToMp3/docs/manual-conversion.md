# Manual conversion lifecycle

## User-visible behavior

Manual conversion runs locally through Rust. The Convert screen observes its
session while the job runs; it does not wait for a completed book before showing
progress. It displays preparation, conversion percentage/chapter counts,
cancellation, errors and confirmed completion. A progress callback reporting
100 percent remains below displayed completion until the executor returns its
validated result.

Cancel requests cooperative termination of this job. The screen stays in the
cancelling state until the writer returns and releases its output ownership and
security-scoped input access. It does not advertise cancellation as completed
while the writer can still publish. A provider failure restores submission and
shows an actionable error. Explicit cancellation is a separate outcome.

The completed result opens from its local snapshot, with no backend lookup or
SSE connection. Local result details show the book, completion and chapter
artifacts. Download, remote-log and raw-payload controls are omitted for this
already-generated local result. Playback starts only through an explicit Play
action; conversion and result inspection do not replace a listening session.

## Responsibility boundaries

| Owner | Responsibility |
| --- | --- |
| ConvertViewModel | Capture the selected file, literal chapter range and per-job voice/options; balance file access |
| ManualConversionSession | Own one task, publish lifecycle/progress, reject duplicate admission and obsolete/foreign callbacks, forward cancellation |
| ManualConversionPresentation | Localized phase/progress text; no conversion or UIKit ownership |
| RustConversionWorkQueues | Separate blocking manual/listening invocations, with serial execution within each purpose |
| RustConversionCoordinator and Rust | Validate options/results, execute conversion, honor job control, retain artifacts and release output leases |
| ConvertScreenController | Observe the session, configure controls, route explicit user actions |

`ManualConversionSession` never receives an audio player or HTTP client. Legacy
submission parameters on the form model remain source-compatible and unused.
The existing four-argument test-executor adapter remains available; production
uses the coordinator's explicit job ID and progress callbacks.

## Why the queues are separate

A listening invocation can wait inside Rust for its playback window to advance.
The previous process-wide serial DispatchQueue also hosted manual invocations,
so a manual conversion could remain queued for the listening session's lifetime.
Each purpose now has one serial queue. This avoids unbounded invocation
parallelism within a purpose while keeping playback-window waits out of the
manual lane. Cancellation requested while queued is checked before entering
the conversion ABI. Each invocation retains its own Rust session, control and
output identity; Rust still owns provider and artifact scheduling.
Piper retains its existing Rust `MODEL_TRANSACTION` around model initialization
and synthesis (`piper_model_preparation.rs`). Separate host invocation queues do
not bypass that transaction or permit model-path identity to change mid-call.

## Regression evidence and final acceptance

`mise run apple:foundation:test` runs the real dispatch queues and session state
without launching an app or loading a model. The blocked-listening regression
failed against the extracted original shared queue and passed after separation.
Tests cover lane serialization, progress before completion, duplicate admission,
provider failure/retry, cancellation propagation, late success, stale/foreign
progress, validation resets and cancellation after committed completion.

`ManualConversionScreenTests` adds UIKit coverage for live table updates,
Cancel, failure recovery and opening the local result without a backend or
playback takeover. These tests and audible/native acceptance remain deferred to
the final iPhone round requested by Pietro. Host queue tests use a bounded
blocking invocation; they do not establish concurrent Piper inference on-device.

Final acceptance includes manual conversion during active and paused listening,
visible progress, cancellation and retry, a provider failure, a completed local
result and preserved playback/book/voice identity. Verify actual files and Rust
writer shutdown rather than inferring completion from the progress label.

## Apple references

Consulted on 2026-10-27; the app retains its iOS 15.5 deployment target.

- [Progress indicators — HIG](https://developer.apple.com/design/human-interface-guidelines/progress-indicators): communicate ongoing progress and offer appropriate interruption controls.
- [Task.cancel](https://developer.apple.com/documentation/swift/task/cancel()): cancellation is cooperative and does not forcibly stop arbitrary work.
- [withTaskCancellationHandler](https://developer.apple.com/documentation/swift/withtaskcancellationhandler(operation:oncancel:)): forward cancellation while awaiting a separately owned task.
