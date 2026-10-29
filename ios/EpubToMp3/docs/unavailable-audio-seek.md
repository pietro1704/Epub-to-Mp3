# Seeking into unavailable audio

The selected timeline value is chapter-relative media time. A seek to 155 seconds
with 15-second chunks must wait for chunk 10 and start five seconds into it. An
exact chunk boundary selects the following chunk; only a confirmed chapter end
permits seeking to the preceding chunk's final endpoint. A missing chunk never
occupies zero seconds in the timeline.

`PendingPlaybackSeek` publishes an explicit `PlaybackNavigationTarget`: chapter
time or a reader page ratio. `ReaderListeningSession` accepts only the current
request/job identity. Saved reader defaults cannot replace a timeline target.
Rust still owns synthesis and chapter priority; Apple playback owns its measured
audio clock and queue backpressure. No time-to-text ratio is sent to Rust for a
timeline seek.

While a target is unavailable, playback stays paused and its exact time and
autoplay intent remain pending. The live AVQueuePlayer items and deferred queue
can be released to unblock the bounded Rust callback. Segment files and measured
durations remain retained, including for a later backward seek. Once contiguous
measured audio covers the target, `StreamedChapterSeek` resolves the containing
segment, in-segment offset and chapter base. Queue replacement checks request
identity again before committing. Duration failure, cancellation, replacement
and stale callbacks cannot silently clamp or resume an obsolete request.

A reader-page start produces a text suffix with an approximate chapter-time
origin. A subsequent timeline seek replaces that job with conversion from the
chapter beginning, retaining the latest request identity, exact selected seconds
and current pause intent. This avoids treating a text ratio as measured audio
time. A newer seek during asynchronous file access supersedes the old open; a
current file-open failure clears the pending seek and reports the failure.
Cancelled playback controls reject late window, priority, position and feedback
operations.

Without a trustworthy source-to-audio timing map, locating an ungenerated time
requires measuring the preceding audio chunks. The producer generates that
prefix through the containing chunk without playing it or waiting for the full
chapter. This change makes no latency or direct random-access synthesis claim.

Fast XCTest runs through `mise run apple:foundation:test`, including measured
segment resolution and cancelled-control wire rejection. Native coverage in
`AudioPlayerUnavailableSeekTests` and `ReaderListeningSeekTests` exercises bounded
delivery, retained earlier audio, conflicting reader defaults, replacement,
pause, stop and current reopen failures. Full UIKit compilation/execution and
visible iPhone acceptance remain deferred to the final campaign. Required
SE1/iOS 15.5 acceptance remains blocked by Simulator quarantine.
