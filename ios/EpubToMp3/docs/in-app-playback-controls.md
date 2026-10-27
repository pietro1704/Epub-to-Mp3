# In-app playback controls

## Starting a session versus controlling one

The mini player and expanded player route Play through `InAppPlaybackRequest`.
This small command selector has no dependency on UIKit, conversion APIs or
global preferences. It invokes exactly one supplied action for each request.

| Current state | Command owner |
| --- | --- |
| No playing audio, queue, conversion, playable chapters or speech fallback | Request listening through the reader's existing startup path |
| Playing audio or loaded queue | Control the existing playback session |
| Conversion already in progress | Control existing playback intent; do not start another producer |
| Restored playable chapters | Resume through the existing playback path |
| Speaking or paused native speech fallback | Control the existing speech session |

`AudioPlayer.inAppPlaybackRequestState` derives these facts from the sole
playback authority. UI components do not store a second transport state.
`ReaderPlaybackTapHandler` retains the existing reader/audio-position decision
when controlling a session. The selector does not bypass that decision.

`FullPlayerScreenController` requires an explicit `onStartListening` action.
`IOSRootContainerController` supplies the same reader startup used by the mini
player. There is no default empty action hiding missing production wiring.
Before this wiring, Play in an empty expanded player could arm pending autoplay
without starting the producer that would supply its first audio.

A rejected startup leaves a later tap retryable. The startup coordinator owns
admission, cancellation and generation identity. The selector does not create
jobs, change the selected voice or claim audio-session ownership.

## Tests and acceptance boundaries

`InAppPlaybackRequestTests` runs through `mise run apple:foundation:test` without
an app, speech synthesis or network requests. It exercises first Play, existing
queues, preparation, saved audio, speech fallback, retry and command isolation.
The initial unconditional transport route failed the first-Play tests; this was
a unit reproduction of that route, not a reproduced physical tap failure.

`ExpandedPlayerTransportTests` sends the actual UIKit button's touch-up action
and checks startup dispatch, repeated preparation taps and pause/resume against
an injected silent speech adapter. These iOS-only tests remain deferred with the
final iPhone journey. Host selector tests do not prove UIKit hit-testing or
audible playback; exercise a fresh book and an existing session on the device.

## Apple guidance

[Playing audio — HIG](https://developer.apple.com/design/human-interface-guidelines/playing-audio)
requires familiar playback-control semantics. Both controls address the same
active session; opening the expanded player does not start an independent one.
The [background-audio contract](background-audio.md) covers the audio session,
system controls and the separate final background-playback journey.
