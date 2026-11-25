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
| Widget case cannot find the app icon or a widget gallery control | The app's widgets live in the Today View; walking the Home Screen is unnecessary | Run `testHomeWidgetsAreOnTheTodayView` (supervised case below) |
| "Activation point invalid and no suggested hit points" on a SpringBoard element | `isHittable` on an element on another page records a failure on iOS 26 | Decide by the element's frame |

## Waiting for an unlock never holds the heavy lease
`scripts/device-workflow.sh` waits for a locked phone (`WAITING_FOR_UNLOCK`, up to 30 min, `DEVICE_UNLOCK_WAIT_SECONDS`) with
no heavy native lease: the wait only queries the device (#1435). The lease is taken after the unlock and held for the real
work; if another job owns it the workflow waits up to `EPUB_NATIVE_WAIT_SECONDS` (one `WAITING_FOR_LEASE` line). If the
30 minutes pass, re-enqueue the same run; do not cancel a run only because the phone is locked.

## Supervised case: `HomeWidgetGalleryUITests` (widgets on the Today View)
Facts measured on the 16e (iOS 26, pt-BR) on 2026-11-24 and confirmed by the owner: the EpubToMp3 widgets live on the **Today
View** (the page to the left of Home Screen page 1), not behind Edit Home Screen; the app icon is on Home Screen page 2. The
case `testHomeWidgetsAreOnTheTodayView` goes to the Today View, attaches a screenshot, the SpringBoard hierarchy and the list of
elements labelled "EpubToMp3", and asserts there is at least one. It needs the app already running in the foreground, so the
workflow alone cannot pass it:
1. Export `TEST_RUNNER_EPUB2MP3_WIDGET_GALLERY=1` and `EPUB2MP3_WIDGET_GALLERY=1` and run the workflow once for
   `EpubToMp3UITests/HomeWidgetGalleryUITests/testHomeWidgetsAreOnTheTodayView` (audited as `@ui-test`). It builds and installs,
   then ends with "XCTest did not verify an executed passing test": expected (the supervisor has not launched the app).
2. Run `TEST_RUNNER_EPUB2MP3_WIDGET_GALLERY=1 mise exec -- ruby scripts/native_job.rb build -- xcodebuild test-without-building
   -xctestrun ios/EpubToMp3/.build/Build/Products/EpubToMp3_iphoneos26.2-arm64.xctestrun -destination id=<xcodeDeviceID from
   the report> -only-testing:EpubToMp3UITests/HomeWidgetGalleryUITests/testHomeWidgetsAreOnTheTodayView
   -parallel-testing-enabled NO -resultBundlePath <new>`.
3. As soon as the log prints the test case start, `xcrun devicectl device process launch --device <id> com.pietrocode.epubtomp3`
   (the case waits 12 s for the app to be in the foreground). The phone must stay unlocked and untouched (~1 min).
4. Close the app afterwards (`devicectl device process terminate --pid`).
Lessons from the iterations: on iOS 26 `isHittable` on an icon that is on another page RECORDS a failure ("Activation point
invalid"): decide by frame; Edit Home Screen's former "+" is a button labelled Editar/Edit; a cold device build can exceed the
workflow's 30 min build limit on this Mac (the next one is incremental).

## iPhone Mirroring (the owner had it active)
- Ran fine with Mirroring active: the unit tests (`EpubToMp3Tests`) and the UIKit presentation tests run through the
  workflow: `RemoteButtonModeRowTests` 1/1 and `ModelsLanguagesScreenIOSTests` 2/2.
- Widget case with Mirroring closed: the 2026-11-24 14:50 recording shows the icon visible on Home Screen page 2 while the
  old gallery walk swiped past it into the App Library, so that failure was the test's timing. Whether Mirroring contributed
  to the earlier morning failure was not established. The Today View case passed on 2026-11-24 16:51 (23 s).
- The Today View case proves the widgets are present; it does not check their layout.
- Not verified: whether Mirroring affects `lockState` (`passcodeRequired`) or the wait for an unlock. The waits seen on
  2026-11-24 happened before Mirroring was known to be active.
