# iOS 17 Simulator Evidence for System Playback Controls

Status: resolved research for [Establish iOS 17 Simulator evidence for system playback controls](https://github.com/pietro1704/Epub-to-Mp3/issues/510).

## Decision

An iOS 17-or-earlier Simulator is an appropriate acceptance environment for the
app-owned streaming queue, durable-local-artifact state, relaunch/offline
workflow, and the wiring of remote-command handlers. It can also support a
manual smoke check that a Now Playing session exposes its metadata and controls
through the simulated system UI, and that a Lock Screen widget can be added.

It is not authoritative proof that Lock Screen, Control Center, background
audio, or audio routing behaves identically to physical hardware. Apple states
that Simulator does not replicate every physical-device feature and directs
developers to a physical device to verify exact behavior. The iOS 17 Simulator
gate must therefore assert the app contract and handler results; a future
physical-device pass remains the hardware-behavior gate.

## Evidence matrix

| Requirement | iOS 17 Simulator evidence | Authoritative automated seam | Boundary |
| --- | --- | --- | --- |
| Stream the first playable segment, queue later segments, and retain the assembled chapter after first play | Run the app with deterministic local segment fixtures; terminate and relaunch after playback begins, then enable Airplane Mode and play the retained local chapter. | XCTest for artifact-manifest transitions, queue ordering, promotion-at-first-play, final-file replacement, and URL resolution after relaunch. | This proves the app's persistence and playback flow, not a production network or hardware-audio route. |
| Manual and automatic offline retention | Inspect the app's downloaded/local state after first play and after a full book finishes; relaunch offline. | XCTest for protected-versus-temporary retention, storage accounting, deletion, and manifest recovery from a process launch. | The test must launch the installed app again without clearing Simulator content. |
| Configurable forward/backward intervals | Change each stored setting to 15, 30, 45, and 60 seconds, then execute the shared action path and assert the resulting position. | XCTest for preference persistence and one transport action used by mini player, expanded player, WidgetKit intent, and remote-command handlers. | `MPSkipIntervalCommand` provides the requested interval in its event; code must use that interval rather than a hard-coded value. |
| Previous/next chapter, including a target still being prepared | Invoke the shared previous/next actions with deterministic queued and unavailable chapters; verify pending intent, priority, and automatic start when media becomes available. | XCTest for boundary behavior and the pending-target state machine. | System UI cannot be treated as the only test driver. |
| Control Center and Lock Screen Now Playing | During local playback, manually open the simulated system UI and use play/pause, skip, and next/previous when exposed; observe that each operation reaches the same action path. | XCTest directly invokes the registered action/handler layer and verifies its state effects. | Apple documents the APIs, but does not promise Simulator reproduces all device features; retain this as a smoke check. |
| Lock Screen widget | Build/run the app target, manually add the accessory widget on the simulated iPhone Lock Screen, and use its supported action. | Widget/unit or UI tests verify the widget's model and deep-link/intent routing. | Apple specifically documents manual addition for Lock Screen accessory widgets. |
| Background and locked playback configuration | Confirm the target declares the audio background mode and code configures/activates a `.playback` audio session; manually lock the Simulator while playback is active. | XCTest validates configuration setup and Now Playing snapshot updates. | A successful Simulator result is not proof of hardware background lifecycle or route behavior. |

## Apple-primary sources

- [Running your app on simulated or physical devices](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices) says Simulator is useful for interactive testing on varied devices, but does not replicate performance or all physical-device features; it directs exact-behavior verification to physical devices.
- [MPRemoteCommandCenter](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter) defines the shared remote-command center for system controls and accessories, including play/pause, track navigation, skip intervals, and position changes.
- [skipForwardCommand](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter/skipforwardcommand) documents that the handler receives the requested skip interval in the event. The matching [skipBackwardCommand](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter/skipbackwardcommand), [previousTrackCommand](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter/previoustrackcommand), and [changePlaybackPositionCommand](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter/changeplaybackpositioncommand) provide the other required transport inputs.
- [MPNowPlayingInfoCenter](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter) documents the system's Now Playing information used for Lock Screen and Control Center media presentation; its guidance pairs the information center with `MPRemoteCommandCenter` actions.
- [AVAudioSession](https://developer.apple.com/documentation/avfaudio/avaudiosession) and [AVAudioSession.Category.playback](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playback) require a playback session; the latter states that continued background playback after screen lock also requires the `audio` background mode.
- [Debugging widgets](https://developer.apple.com/documentation/widgetkit/debugging-widgets) says Lock Screen accessory widgets are manually added after running the app target, which makes a manual simulator validation possible.
- [UserDefaults](https://developer.apple.com/documentation/foundation/userdefaults) describes persistent local storage for app preferences. [Preserving your app's UI across launches](https://developer.apple.com/documentation/uikit/preserving-your-app-s-ui-across-launches) describes state saved to disk and restored after launch; the durable audio manifest must use an equivalent local storage contract.

## Required iOS 17 Simulator acceptance run

1. Start deterministic progressive conversion; begin playback at the first available segment.
2. Exercise mini player, expanded player, and direct remote-handler XCTest seams for play/pause, previous/next, and independently configured forward/back values.
3. Lock the simulated device and manually inspect/use available Now Playing and Control Center controls; manually add and use the Lock Screen widget.
4. Terminate and relaunch the app without uninstalling or resetting the simulator; enable Airplane Mode; resume every chapter that had begun playback and the fully heard book.
5. Verify a queued unavailable target remains pending, receives priority, and autoplays when its first segment arrives.

Record any absent or noninteractive Simulator system surface as an environment limitation, not a passing result. The automated handler and artifact-state assertions remain required in that case.
