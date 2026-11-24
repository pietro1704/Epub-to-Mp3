# Physical iPhone runs: waiting, supervised cases and iPhone Mirroring

Facts recorded on 2026-11-24 with the iPhone 16e (`44B2CFBD-2193-5086-8E8D-BF7A2876C321`, iOS 26) and the Intel Mac.
Execution authority stays in [execution policy](execution-policy.md).

## Preflight before any physical iPhone run
At least five sessions up to 2026-11-24 lost a device run before any test executed. Before building:
1. Ask Pietro once, in one message and before the build, for everything only a human can do: Developer Mode on, Settings >
   Developer > Enable UI Automation granted, the Mac trusted, Auto-Lock set to Never for the session, and iPhone Mirroring
   closed when the case drives SpringBoard. Never start the build and discover these afterwards.
2. Build while the phone stays locked (`build-for-testing`); ask for the unlock only for the run step
   (`test-without-building`). Gate the run with `xcrun devicectl device info lockState --device <id>`.
3. Confirm the Xcode selection is the expected one (`xcode-select -p`, `DEVELOPER_DIR`) and that mise does not override it
   (see the toolchain section of the [execution policy](execution-policy.md)).
4. Rebuild the FFI through the repository task when Rust changed; never test against an older signed FFI copy.
5. iPhone jobs come first in the queue; while the phone is held, report why it is not running a test.

## Failure signatures
Map each new device failure to a row here so later runs apply the fix instead of rediscovering it.

| Symptom | Cause | Fix |
| --- | --- | --- |
| Test runner fails at start with a LocalAuthentication error (-1) | UI Automation not enabled/authorized on the phone | Pietro enables Settings > Developer > Enable UI Automation; ask before the build (preflight 1) |
| `WAITING_FOR_UNLOCK`, `passcodeRequired`, or the phone locks during the build | Auto-Lock while the build runs | Build locked, ask one unlock right before the run step; Auto-Lock Never during supervised sessions |
| UI test stalls on the "Continue from where?" dialog | The resume prompt is an app dialog, not a system alert | Handle it explicitly in the test by accessibility identifier; interruption monitors only cover system alerts |
| UI test taps the wrong Play button | Label query matches more than one control | Query by accessibility identifier, scoped to the intended container |
| Device behavior does not match the Rust change | Stale signed FFI copy in the build products | Rebuild the FFI through the repository task, then rebuild the test bundle |
| Swift 6 actor-isolation errors surface during the device build | Isolation mismatch not caught before the device step | Fix with a Mac or CI build first; the device run is not the compiler check |
| Widget case cannot find the app icon on the Home Screen | Widgets live in the Today View; Mirroring may also interfere | See the supervised widget case below; close Mirroring and print SpringBoard labels before asserting |

## Waiting for an unlock never holds the heavy lease
`scripts/device-workflow.sh` waits for a locked phone (`WAITING_FOR_UNLOCK`, up to 30 min, `DEVICE_UNLOCK_WAIT_SECONDS`) with
no heavy native lease: the wait only queries the device (#1435). The lease is taken after the unlock and held for the real
work; if another job owns it the workflow waits up to `EPUB_NATIVE_WAIT_SECONDS` (one `WAITING_FOR_LEASE` line). If the
30 minutes pass, re-enqueue the same run; do not cancel a run only because the phone is locked.

## Supervised case: `HomeWidgetGalleryUITests` (WidgetKit gallery)
The case drives SpringBoard and needs the app already running in the foreground, so the workflow alone cannot pass it:
1. Export `TEST_RUNNER_EPUB2MP3_WIDGET_GALLERY=1` and `EPUB2MP3_WIDGET_GALLERY=1` and run the workflow once for
   `EpubToMp3UITests/HomeWidgetGalleryUITests/testHomeWidgetPreviewsAreAvailableInTheSystemGallery` (audited as `@ui-test`).
   It builds and installs, then fails with "The supervisor must launch the app": expected.
2. Run `TEST_RUNNER_EPUB2MP3_WIDGET_GALLERY=1 mise exec -- ruby scripts/native_job.rb build -- xcodebuild test-without-building
   -xctestrun ios/EpubToMp3/.build/Build/Products/EpubToMp3_iphoneos26.2-arm64.xctestrun -destination id=<xcodeDeviceID from
   the report> -only-testing:EpubToMp3UITests/HomeWidgetGalleryUITests/... -parallel-testing-enabled NO -resultBundlePath <new>`.
3. As soon as the log prints the test case start, `xcrun devicectl device process launch --device <id> com.pietrocode.epubtomp3`
   (the case waits 12 s for the app to be in the foreground). The phone must stay unlocked and untouched (~10 min).
4. Close the app afterwards (`devicectl device process terminate --pid`).

## iPhone Mirroring (the owner had it active)
- Ran fine with Mirroring active: the unit tests (`EpubToMp3Tests`) and the UIKit presentation tests run through the
  workflow: `RemoteButtonModeRowTests` 1/1 and `ModelsLanguagesScreenIOSTests` 2/2.
- The supervised widget case reached SpringBoard (the three `swipeLeft` events were synthesized) but then failed
  `HomeWidgetGalleryUITests.swift:25`, "The app icon must be on the Home Screen": no hittable icon matched
  `label CONTAINS[c] "EpubToMp3"` after three swipes. Not established whether Mirroring, the icon label ("Epub-to-Mp3" is the
  Mac app name) or an App Library placement caused it. Next try: Mirroring closed, and print the SpringBoard icon labels
  before the assertion.
- Not verified: whether Mirroring affects `lockState` (`passcodeRequired`) or the wait for an unlock. The waits seen on
  2026-11-24 happened before Mirroring was known to be active.
