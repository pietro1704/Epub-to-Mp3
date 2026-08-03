# iOS in-process Edge conversion and playback research — 2026-07-30

Status: the macOS embedded-runtime streaming test and arm64 iPhone bundle
installation have passed; a real iPhone Listen/stream/playback smoke remains
pending while the connected device is locked.

## Decision

For iPhone, keep conversion **in the app process**. The local service boundary
is `EmbeddedConversionCoordinator`, not a loopback FastAPI/Hypercorn server:

```text
bundled Python conversion rules
        ↕ PythonKit (one serialized interpreter boundary)
Swift Edge transport (`URLSessionWebSocketTask`, WSS)
        ↓ ordered MP3 segment events
temporary local MP3 files → `AVPlayerItem` → `AVQueuePlayer`
        ↓
AVAudioSession / Now Playing / remote controls
```

`URLSessionWebSocketTask` is Apple's WebSocket API: it has asynchronous binary
and text messages, supports authentication and redirects through task-delegate
methods, and uses `ws`/`wss` URLs. This is the right native transport for the
existing Microsoft Edge protocol. Use `wss` and preserve normal server-trust
evaluation; App Transport Security (ATS) requires strong TLS for URL Loading
System traffic and Apple recommends fixing a server instead of weakening ATS.
[URLSessionWebSocketTask](https://developer.apple.com/documentation/foundation/urlsessionwebsockettask)
[ATS](https://developer.apple.com/documentation/security/preventing-insecure-network-connections)

Do not introduce a local HTTP server just to call it from the same process.
It adds HTTP lifecycle, port, and background-state failure modes but does not
improve the conversion or playback contract. It would also obscure the useful
separation that already exists: Python owns portable conversion policy while
Swift owns iOS networking and playback.

## Apple-platform constraints

- Bundle the interpreter, Python standard library, and all executable Python
  modules with the app. Do not download Python source, wheels, or executable
  extensions at runtime. App Review Guideline 2.5.2 requires a self-contained
  app bundle and prohibits downloaded/installed/executed code that changes the
  app's functionality. A bundled interpreter is not an automatic approval;
  it needs an on-device release build and normal App Review scrutiny.
  [App Review Guidelines 2.5.2](https://developer.apple.com/app-store/review/guidelines/)
- Keep the current Swift-owned networking seam. It avoids making the embedded
  CPython runtime load Python networking extensions and uses a public iOS
  framework for TLS and WebSockets. Do not attempt to launch the Python CLI
  as a child process on iOS; the design must remain in-process.
- A background `URLSessionConfiguration` is for HTTP/HTTPS uploads and
  downloads. Therefore it is not a durable-WebSocket solution (an inference
  from the documented supported background task types). Persist conversion
  state after every completed segment/chapter and reconnect/retry only after
  the app is active again.
  [URLSessionConfiguration](https://developer.apple.com/documentation/foundation/urlsessionconfiguration)

## Transport and conversion contract

Use a fresh, cancellable WebSocket task for each Edge request unless a measured
protocol-compatible benchmark proves otherwise. The native bridge must:

1. create the `URLSessionWebSocketTask` with the WSS request and resume it;
2. send the Edge configuration and SSML frames;
3. receive until the protocol terminal frame, collecting only valid audio
   payloads;
4. cancel on cancellation, timeout, malformed frames, or a missing terminal
   frame; and
5. return a typed failure to the Python retry/orchestration layer.

The existing `EdgeTTSBridge` has this basic shape. Its session is scoped to a
single request and it cancels on timeout/terminal completion, which matches
the lifecycle above. Its WSS endpoint also avoids an ATS exception. This is
not a recommendation to use a background WebSocket; foreground conversion is
the reliable user-facing mode.

The network protocol must not be allowed to dictate playback order. Every
segment event needs a stable `(chapterIndex, segmentIndex)` identity. If
future performance work starts multiple chunk requests concurrently, hold
out-of-order completions in a reorder buffer and enqueue only the next
expected segment. `AVQueuePlayer` plays the sequence in its queue; emitting
items in network-completion order would narrate chunks out of order.
[AVQueuePlayer](https://developer.apple.com/documentation/avfoundation/avqueueplayer)

### CLI-parity finding

The current in-process streaming path is functional architecture, but it does
**not yet prove “exactly the same as the Python CLI.”** Specifically:

- `EmbeddedConversionCoordinator.stream` parses the book then loops through
  `PythonBridge.convertChapterStreaming` one chapter at a time.
- That bridge calls `ios_entrypoints.synthesize_chapter_streaming`, not
  `AudioConverter._convert_chapters_parallel()`.
- `ios_entrypoints` describes itself as Edge-only; its Piper transport is a
  stub, and its retry/fallback, audio validation, telemetry, adaptive throttle,
  and chapter-parallel policies differ from `converter.py`.
- `PythonBridge.convertChapterParallel` exists, but its callback is delivered
  as a request completes. It must not become the streaming source without the
  ordering barrier above.

The required implementation direction is to extract or expose the portable
CLI conversion policy behind an injected `synthesize_chunk` transport and an
ordered segment callback. The CLI supplies its normal Edge transport; iOS
supplies `EdgeTTSBridge`. Then add contract tests that feed identical EPUB,
voice, options, synthetic success/failure schedule, and transport bytes to
both adapters and compare chapter selection, chunk boundaries, retry outcome,
ordered output bytes, cache decisions, and terminal errors. A separate real
iPhone test must prove the actual Edge network and playback round trip.

## Streaming audio playback

`AVQueuePlayer` is the appropriate player: Apple defines it as a player for a
sequence of `AVPlayerItem`s and provides `insert(_:after:)` for appending
items. `AVPlayer` supports local file-based MP3 assets, and its periodic time
observer is the appropriate API for continuous playback-position UI updates.
[AVQueuePlayer](https://developer.apple.com/documentation/avfoundation/avqueueplayer)
[AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer)

For each ordered MP3 segment:

1. write to a unique file atomically in an app-owned temporary directory;
2. create `AVPlayerItem(url:)` after the write completes;
3. insert it after the queue tail on the main actor;
4. start only after explicit user intent (or a previously armed explicit
   Listen action); and
5. retain enough queued segments to survive normal network jitter, without
   unbounded memory/disk growth.

The current `AudioPlayer.enqueueSegment` already uses file-backed temporary
segments and `AVQueuePlayer`, tracks the active item, and removes the session
temporary directory during teardown. Keep those properties. Observe
`AVPlayerItem.didPlayToEndTimeNotification` and `currentItem` to update chapter
state, but dispatch observer work safely because Apple notes the end
notification can arrive on a different thread.
[AVPlayerItem end notification](https://developer.apple.com/documentation/avfoundation/avplayeritemdidplaytoendtimenotification)

## Background playback, interruptions, and lock screen

Declare `UIBackgroundModes = audio` in the *built iOS target* and configure
the shared audio session as `.playback` with spoken-audio/long-form options.
Apple states that `.playback` supports playback with the device silent and,
with the Audio/AirPlay/Picture in Picture background mode, background audio.
Activate the session when playback starts, not merely when conversion emits a
segment, so the app does not steal audio focus from another player.
[AVAudioSession](https://developer.apple.com/documentation/avfaudio/avaudiosession)
[UIBackgroundModes](https://developer.apple.com/documentation/BundleResources/Information-Property-List/UIBackgroundModes)

The current `AudioPlayer` already follows this design: it sets `.playback`,
`.spokenAudio`, `.longFormAudio`, activates lazily, and its XcodeGen settings
generate the `audio` background mode. Verification must inspect the generated
device app's Info.plist, not only the source plist.

Observe interruptions and route changes. On interruption end, resume only
when the system includes `shouldResume` and the app was playing before the
interruption. On `oldDeviceUnavailable`, pause rather than exposing audiobook
audio after headphone removal. Apple notes that `AVPlayer` itself responds to
these events; observers are still needed to keep app state and UI correct.
[Handling audio interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)
[Responding to audio route changes](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes)

Publish the currently playing chapter, book, elapsed time, duration, and
playback rate to `MPNowPlayingInfoCenter`; it feeds Lock Screen, Control
Center, AirPlay, and accessories. Register `MPRemoteCommandCenter.shared()`
handlers for play, pause, toggle, seek, skip, next/previous chapter, and rate.
The current `AudioPlayer` already registers these handlers and creates Now
Playing metadata; keep its explicit removal of command targets in `deinit`.
[MPNowPlayingInfoCenter](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter)
[MPRemoteCommandCenter](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter)

Background audio is not permission for an unlimited, invisible conversion
job. On background entry, persist the last completed segment/chapter and
cleanly cancel or checkpoint an in-flight request. `beginBackgroundTask` is
only a finite grace period for critical finalization; it requires an expiration
handler and a matching end call. `BGProcessingTask` runs when the device is
idle and may be interrupted, so it is appropriate for cache maintenance or a
later best-effort conversion pass, not a live Listen promise.
[Extending background execution](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)
[Choosing background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)

## Local audio data

Use `tmp` only for the not-yet-finalized segment files. Apple says the system
may purge `tmp` while the app is not running, so remove them as soon as the
queue no longer needs them. Keep complete, user-visible downloads in the
existing app-managed audiobook store; keep re-creatable conversion output and
text cache in `Library/Caches` where possible. If output remains in
Application Support, set `isExcludedFromBackup` on the root and each newly
written output. Apple explicitly requires excluding recreatable/downloadable
large media from backups.
[Using the file system effectively](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively)
[isExcludedFromBackupKey](https://developer.apple.com/documentation/foundation/urlresourcekey/isexcludedfrombackupkey)

The embedded conversion output currently goes to Application Support without
an explicit backup-exclusion write. Correct that before shipping a large-book
workflow. For audio that must keep playing after the screen locks, inspect and
set the file-protection policy deliberately. `completeUntilFirstUserAuthentication`
keeps the encrypted file accessible after the first device unlock, including
when the user locks it later; it is the relevant candidate for queued local
audio. Do not lower protection without a demonstrated playback need.
[FileProtectionType.completeUntilFirstUserAuthentication](https://developer.apple.com/documentation/foundation/fileprotectiontype/completeuntilfirstuserauthentication)

## Acceptance evidence before claiming completion

1. Real iPhone, fresh install: import an EPUB, start Edge conversion, and
   hear the first local segment while later segments convert.
2. Lock screen/background: playback continues; lock-screen title/chapter,
   elapsed time, play/pause, skip, seek, and rate commands work.
3. Interruptions: an incoming interruption pauses; it resumes only when iOS
   permits it; unplugging headphones never starts speaker playback.
4. Network loss: current request reports a visible error/checkpoint; reopening
   resumes deterministically without duplicate or reordered segments.
5. CLI-parity contract suite: identical deterministic transport fixture
   produces the same ordered per-chapter outputs and retry/validation result.
6. Device storage audit: no stale `tmp` session after playback ends, cache
   eviction works, and output files are excluded from backup as intended.
