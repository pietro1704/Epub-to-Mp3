# Physical iPhone runs: waiting, supervised cases and iPhone Mirroring

Facts recorded on 2026-11-24 with the iPhone 16e (`44B2CFBD-2193-5086-8E8D-BF7A2876C321`, iOS 26) and the Intel Mac.
Execution authority stays in [execution policy](execution-policy.md).

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
- Mirroring is not a substitute for an unlocked phone: while it was active `lockState` still reported `passcodeRequired: true`
  at times and runs waited.
