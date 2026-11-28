# Physical iPhone runs: waiting, supervised cases and iPhone Mirroring

Facts recorded on 2026-11-24 with the iPhone 16e (`44B2CFBD-2193-5086-8E8D-BF7A2876C321`, iOS 26) and the Intel Mac.
Execution authority stays in [execution policy](execution-policy.md).

## Preflight before any physical iPhone run
At least five sessions up to 2026-11-24 lost a device run before any test executed. Before building:
1. Ask Pietro once, in one message and before the build, for everything only a human can do: Developer Mode on, Settings >
   Developer > Enable UI Automation granted, the Mac trusted, Auto-Lock set to Never for the session, and iPhone Mirroring
   closed when the case drives SpringBoard. Never start the build and discover these afterwards.
2. Run through `scripts/device-workflow.sh`, which works like Xcode: it builds without depending on the phone, then waits
   until the phone can run the test (see "Waiting for the phone"). Do not ask Pietro to confirm the unlock.
3. Confirm the Xcode selection is the expected one (`xcode-select -p`, `DEVELOPER_DIR`) and that mise does not override it
   (see the toolchain section of the [execution policy](execution-policy.md)).
4. Rebuild the FFI through the repository task when Rust changed; never test against an older signed FFI copy.
5. iPhone jobs come first in the queue; while the phone is held, report why it is not running a test.

## Failure signatures
Map each new device failure to a row here so later runs apply the fix instead of rediscovering it.

| Symptom | Cause | Fix |
| --- | --- | --- |
| Test runner fails at start with a LocalAuthentication error (-1) | UI Automation not enabled/authorized on the phone | Pietro enables Settings > Developer > Enable UI Automation; ask before the build (preflight 1) |
| `WAITING_FOR_UNLOCK`, `passcodeRequired`, or the phone locks during the build | Auto-Lock while the build runs | Let the workflow wait; do not ask for a confirmation. Auto-Lock Never during supervised sessions |
| `CoreDeviceError 10004`, "Failed to get launch progress", "process identifier of the launched application could not be determined" before any touch | Not established. Seen twice on the 16e on 2026-11-27 with `test-without-building -xctestrun`; in one of them XCTest waited on another app that was in front. A project-based `xcodebuild test` passed earlier that day | The workflow waits and launches again (`WAITING_FOR_FOREGROUND`) |
| UI test stalls on the "Continue from where?" dialog | The resume prompt is an app dialog, not a system alert | Handle it explicitly in the test by accessibility identifier; interruption monitors only cover system alerts |
| UI test taps the wrong Play button | Label query matches more than one control | Query by accessibility identifier, scoped to the intended container |
| Device behavior does not match the Rust change | Stale signed FFI copy in the build products | Rebuild the FFI through the repository task, then rebuild the test bundle |
| Swift 6 actor-isolation errors surface during the device build | Isolation mismatch not caught before the device step | Fix with a Mac or CI build first; the device run is not the compiler check |
| Widget case cannot find the app icon or a widget gallery control | The app's widgets live in the Today View; walking the Home Screen is unnecessary | Run `testHomeWidgetsAreOnTheTodayView` (supervised case below) |
| "Activation point invalid and no suggested hit points" on a SpringBoard element | `isHittable` on an element on another page records a failure on iOS 26 | Decide by the element's frame |

## Waiting for the phone
`scripts/device-workflow.sh` never needs a human to say the phone is ready. Both waits are bounded by
`DEVICE_UNLOCK_WAIT_SECONDS` (default 30 min each) and hold no heavy native lease while they sleep:

- **Locked** (`WAITING_FOR_UNLOCK`): the workflow polls `lockState` every 5 s. The lease is taken after the unlock (#1435).
- **App cannot come to the front** (`WAITING_FOR_FOREGROUND`): `devicectl` is not used to ask which app is in front, because
  we know of no query for it. Instead, when every error of a test launch is "Failed to get launch progress … could not be
  determined" and no test passed, nothing was touched: the workflow waits 15 s, checks the lock again and launches again
  without rebuilding. It deletes the result bundle of that launch unread, because it may hold a recording of another app.
  Any other test failure ends the run at once.

If another job owns the lease, the workflow waits up to `EPUB_NATIVE_WAIT_SECONDS` (one `WAITING_FOR_LEASE` line). When a
wait times out the report says `blocked`; re-enqueue the same run. This changes only when a run starts: tests still touch
only our app, and a case that finds another app or a system alert in front still stops.
Not verified on a device: that the second launch succeeds once the other app leaves the front.

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
