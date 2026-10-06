# Bug: Auto reader theme does not synchronize app UI

- Type: bug
- State: implementing
- Scope: Flutter app theme selection; keep reader and MaterialApp synchronized.
- User symptom: Auto mode shows dark reader text/background while the surrounding UI remains light.
- Root cause hypothesis: `MaterialApp.themeMode` reads only legacy `settings.darkMode`; reader colors resolve `ReaderTheme.auto` from platform brightness independently.
- Acceptance criteria:
  - Auto + dark platform brightness selects `ThemeMode.dark` for the full app UI.
  - Auto + light platform brightness selects `ThemeMode.light`.
  - Explicit reader themes preserve their expected light/dark UI brightness.
  - Existing reader color behavior remains unchanged.
  - Flutter tests, analyze, debug APK build, and real-device smoke check pass.
- Verification plan: failing unit test for shared theme-mode resolution, fix, unit test, full Flutter test/analyze, build/install device and inspect UI.

## Execution Log

### 2026-10-03 — triage

- Evidence: `main.dart:212` used `settings.darkMode ? ThemeMode.dark : ThemeMode.light`; `reader_theme_colors.dart:10-18` resolved Auto from `platformDispatcher.platformBrightness`.
- Fact: these paths can disagree by design when `readerTheme == ReaderTheme.auto` and system brightness is dark.
- Decision: centralize the UI theme-mode resolution beside reader theme resolution and reuse it from `MaterialApp`.
- Next step: add a red-capable regression test before the implementation.

### 2026-10-03 — implementation and verification

- Regression test added in `flutter_app/test/reader_theme_colors_test.dart` for Auto + dark/light platform brightness.
- Fix: added `ReaderThemeColors.themeMode()` and changed `MaterialApp.themeMode` in `flutter_app/lib/main.dart` to use `settings.readerTheme` instead of legacy `settings.darkMode`.
- Focused test: `mise exec -- flutter test test/reader_theme_colors_test.dart` — 11 tests passed.
- Full tests: `mise run flutter:test` — 367 tests passed.
- Static analysis: `mise run flutter:analyze` — no issues found.
- Build: `mise run flutter:build-apk-debug` — APK built successfully.
- Device attempt: installation/smoke launch was blocked because serial `52008714b40355ad` disconnected immediately after the build; `adb devices -l` and ADB restart currently show no devices.
- Fact: code/tests/build are verified; visual device verification is not yet verified.
- Status: blocked on device reconnection; do not mark verified until the fixed APK is installed and the UI screenshot confirms dark global chrome in Auto mode.
- Next step: reconnect the Samsung device, install the already-built `flutter_app/build/app/outputs/flutter-apk/app-debug.apk`, launch, and capture the UI in Auto mode.

### 2026-10-03 — system-following correction and final-run block

- User clarification: Auto UI must follow the device system Light/Dark mode, not merely copy a one-time brightness value.
- Fix: `ReaderThemeColors.themeMode(ReaderTheme.auto)` now returns `ThemeMode.system`; explicit reader themes still map to their corresponding fixed UI brightness.
- Regression test updated to require `ThemeMode.system` for Auto under both dark and light platform inputs.
- Verification: focused test and `mise run flutter:test` passed with 367 tests; `mise run flutter:analyze` passed; `mise run flutter:build-apk-debug` passed.
- Final app-run attempt: APK built, but `adb devices -l` listed no devices; ADB daemon restart had the same result.
- Status: code/build/tests verified; real-app visual verification remains blocked and plan is not verified.
- Next step: reconnect `52008714b40355ad`, install `flutter_app/build/app/outputs/flutter-apk/app-debug.apk`, launch the app, capture Light/Dark screenshots, and switch the system mode to confirm dynamic UI synchronization.

### 2026-10-03 — reconnection and wireless fallback attempt

- USB check: `adb devices -l` returned no devices.
- Wireless discovery: `adb mdns services` found no ADB services.
- macOS USB check: `system_profiler SPUSBDataType` did not identify the Samsung; only unrelated USB interface warnings were returned.
- Wireless fallback: tested ADB TCP ports 5555/5556 on hosts already present in the local ARP table; no port responded.
- Status: final app execution remains blocked by device visibility. No visual verification claim.
- Next step: enable USB debugging/authorization or Wireless debugging on the Samsung, then provide/use its displayed IP:port or reconnect the cable; rerun install, launch, and Light/Dark screenshot verification.
