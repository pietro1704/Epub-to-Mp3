# Background audiobook playback

## Application contract

User-initiated audiobook playback continues when the app moves to the
background or the user opens Control Center or Notification Center. Opening an
overlay is not a request to pause. This does not guarantee playback after an
explicit force-quit or ignore genuine system audio interruptions.

The application Info.plist declares `UIBackgroundModes` as an array containing
`audio`. Keep this typed declaration in `EpubToMp3/Resources/Info.plist`, which
the application target processes through `INFOPLIST_FILE`. A scalar
`INFOPLIST_KEY_UIBackgroundModes` build setting does not establish this required
array in the packaged application.

## Ownership

- `PlaybackSystemSession` configures the playback audio session lazily, owns
  system notifications and remote-command registrations, and releases them with
  its owner. The primary category is playback, with spoken-audio mode and
  long-form-audio route-sharing policy.
- `AudioPlayer` and its transport own the active playback session. Scene
  backgrounding persists the resume point; it must not create a second player
  or pause the current one.
- Rust retains conversion, chunk generation, cancellation and artifact ownership.
  Background playback capability is not a guarantee of unlimited background
  computation or network availability.
- Genuine interruptions and disconnected headphones retain the platform's
  interruption/privacy semantics. Background permission must not override an
  intentional user pause.

The metadata repair introduces no additional runtime owner, interface or
dependency. UI layout and expanded-player controls are separate responsibilities.

## Regression coverage and acceptance

`BackgroundAudioConfigurationTests` runs in `mise run apple:foundation:test`
without an app launch. It checks the typed application metadata on the host.
When run in the iOS XCTest target, the same assertion reads the actual host
application bundle, catching packaging omissions as well as a wrong value type.
The XCTest does not synthesize speech, access models or require a device.

Metadata tests establish the required configuration, not audible background
continuity. Final physical-device acceptance must verify:

1. Start known audiobook audio and note the active voice/chapter/position.
2. Open and dismiss Notification Center and Control Center during playback.
3. Switch to another app, return Home and lock/unlock the phone.
4. Verify continuous audio and position across a prepared chunk boundary;
   separately check a boundary requiring additional generation.
5. Pause intentionally and repeat background/foreground transitions: playback
   must stay paused. Exercise genuine interruptions and headphone removal.
6. Confirm there is one playback session and system controls address it.

Physical-device acceptance is deferred to the final combined iPhone journey
requested by Pietro. No metadata assertion substitutes for that journey.

## Apple references

Consulted on 2026-10-27; the app retains its iOS 15.5 deployment target.

- [Configuring your app for media playback](https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback): playback category and Audio, AirPlay, and Picture in Picture background capability.
- [Playing audio — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/playing-audio): audiobook background playback, system controls and headphone-disconnection expectations.
- [Handling audio interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions): observe interruption notifications on supported deployment targets and reactivate/resume appropriately. Newer lifecycle APIs described for iOS 27 are not used by this iOS 15.5-compatible repair.
