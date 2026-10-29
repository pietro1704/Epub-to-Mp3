# Download management

Settings exposes removal only under Storage. Temporary generated audio cleanup,
all retained-download removal and per-book management remain distinct actions
with their existing scope-specific confirmations. The duplicate Advanced action
that also cleared every download has been removed. Model management stays
separate and these actions do not delete source books or installed models.

Per-book deletion uses `BookAudioRemoval` to serialize confirmed attempts for
the same literal book identity while allowing another book's independent action.
Errors and cancellation propagate; a failed request does not clear the library's
offline flag. Successful deletion commits that selected book's flag only after
the operation returns. Cancellation is checked before deletion; an already
completed filesystem mutation cannot be rolled back by later cancellation.

A listing error keeps the last valid downloaded-book list and reports a failure
instead of replacing it with an empty success state. The storage owner continues
to control retained/temporary audio and partial filesystem failures. Player
transport is not reset or replaced by this presentation path. Actual behavior
while playing retained audio still requires the final native app journey.

Foundation tests reproduce swallowed errors, duplicate and cancelled attempts,
then verify success/retry/cancellation and book identity through the production
removal owner. Native UIKit regressions exercise confirmations, the single
management location and actual per-book filesystem success plus injected
failure/cancellation, preserving another book and unrelated fixture bytes.
Their execution and active-playback acceptance remain pending final validation.
