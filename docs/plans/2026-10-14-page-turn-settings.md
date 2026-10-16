# Page-turn and settings regression repair

Status: verified; delivered with the focused correction slice.

Scope: repair the user's page-turn animation and settings-cell layout defects.
Confirm the affected settings surface and animation symptom through native
execution and any user clarification before selecting a correction.

Non-goals: redesign, conversion/provider changes, unrelated reader geometry,
other screen audits, PR/merge or CI monitoring.

Candidate files: BookOpenScreenController.swift, ReaderSettingsScreenController.swift,
SettingsScreenController.swift, IOSFormCells.swift and matching native tests.
MacReaderViewController.swift only if the same defect is reproduced on macOS.
Actual macOS window verification uses NativeResponsiveScreenTests in the
existing hosted XCTest target and the shipping application delegate/window
factory. No new production target or automation service is required.

Risks: snapshots may expose stale content; changes to cells may affect reuse
and self-sizing. Preserve exact chrome offsets and canonical page navigation.

Acceptance: a failing native reproduction for each reported defect, passing
permanent regressions after the smallest fix, actual app exercise on macOS
and iPhone SE/iOS15.5, seeded LOTR pagination/chrome with zero clipped lines.
Run targets serially with the existing guard and leave only the exact SE open.
Review final diff against this scope and record exact results and limitations.

Discovery: required Xcode16.4 iOS and macOS destinations are available.
Existing animation tests observe overlays but do not prove visual fold quality.
Settings cells have separate general-settings and reader-settings paths;
the reproduced cell defect is in the reader-settings surface.

## Reproduction and execution

- Exact SE initial build passed with Xcode16.4. Existing UI tests failed:
  curl overlay was already gone when queried; margin test queried UISlider
  although the app uses CompactSlider. These failures alone do not establish
  the reported visual defects. Result: simulator-smoke-26A9C5DD-8F3B-4C10-B7FD-2D0D95B8A2A9.
- Added a native compact reader-settings cell test. It failed because the
  real font-size cell contained no CompactSlider after layout (result
  simulator-smoke-9A16FF77-0E36-496C-A4D7-FCEBAEDBC497).
- Installing slider controls after contentConfiguration fixes that removal.
  The same native test passed for font size, line spacing and margin with
  labels above controls (simulator-smoke-6F1F2B27-FC3E-4FD0-8904-291CB2C6A417).
  Actual UI exercise and accessibility/reuse QA subsequently passed below.
- Direct native animation tests use a UIWindow attached to the real app scene.
  Their red run confirmed forward anchorPoint.x=1 instead of 0, backward
  terminal transform folded instead of flat, and missing chapter-boundary
  overlays (simulator-smoke-61C5354F-FA22-463A-83F0-E0926C47BD16).
- Corrected forward spine, backward incoming-page unfolding and chapter
  transitions. Fourteen focused native/GUI tests passed without failures or
  skips (simulator-smoke-3D6767CB-0298-48A0-B706-61B6E37B7450).
- Adversarial QA reproduced a missing glyph-protection mask in the turning
  snapshot at raw offset 11 (simulator-smoke-B9422812-770A-4CC6-98A7-FC06690C35A1).
  Snapshot now carries the actual viewport masks. Focused final verification passed below.
- Strengthened cell tests with title/value presence, slider/non-slider reuse,
  reload, reading-mode change and accessibility XXXL. Replaced the timing-sensitive
  UI overlay assertion with settled real page movement/clipping; direct native
  tests retain transient animation proof.
- Standards and Spec reviews found no blocking product defect. Their concrete
  findings were addressed: title presence, reuse coverage and XcodeGen generation
  under the native lease. The macOS GUI test depends on the existing imported LOTR
  and current app preferences; it is actual-app evidence, not a hermetic fixture.

## Final evidence and limits

- Exact iPhone SE (1st generation), iOS15.5, Xcode16.4: 17 focused native/GUI
  tests passed, zero failures/skips. Command: `IOS_SIMULATOR_UDID=C66CCB36-C43E-4174-861E-2FA713389C84 IOS_TESTS=EpubToMp3Tests/NativeFormAccessibilityTests,EpubToMp3Tests/ReaderViewportConfigurationTests,EpubToMp3UITests/ReaderFlickerUITests/testPageTurnDuringChromeToggleDoesNotFlicker,EpubToMp3UITests/ReaderModesUITests/testAnimatedForwardAndBackwardTurnsRestoreThePage,EpubToMp3UITests/ReaderModesUITests/testMarginSliderChangesTheOpenTextViewportDuringEditing,EpubToMp3UITests/ReaderModesUITests/testReduceMotionSkipsThePageCurl mise run ios:simulator:smoke:test`.
  Result: `.reports/simulator-smoke-750136A5-89ED-4E1F-A41D-984C29A0C6B6/tests.xcresult`;
  raw log: `/tmp/page-turn-settings-final-focused.log`.
- Native Mac: real LOTR chapter-boundary, resized Settings and reader appearance
  tests passed 3/3 in the 15:26:49 EpubToMp3Mac result bundle.
- Actual shipping Mac window factory: `APPLE_NATIVE_TESTS=EpubToMp3Tests/NativeResponsiveScreenTests/testLiveMacWindowSettingsAndLOTRPageRoundTrip mise run apple:chapter-callback:test`
  passed 1/1, zero failures/skips. Final result:
  `ios/EpubToMp3/.build/Logs/Test/Test-EpubToMp3Mac-2026.10.14_16-02-34--0300.xcresult`;
  raw log: `/tmp/page-turn-settings-mac-live-isolated.log`. It resized the real root window,
  exercised installed Settings controls, opened existing LOTR, and sent native
  right/left key events with exact viewport restoration. This hosted test
  constructs the shipping application delegate because the XCTest bootstrap
  intentionally skips normal app startup; it does not construct substitute
  screen controllers. The app was subsequently built/launched normally with
  `mise run mac:run`, then terminated before SE verification.
- Earlier Mac runs failed xcresult serialization (`mkstemp`/CASDB), despite
  successful executable test verdicts retained in staged diagnostic logs.
  The final isolated run serialized successfully and its summary confirms 1/1.
  Review corrected the test to snapshot preferences before app startup and
  restore playback/reader/library/widget keys after all owned teardown callbacks.
  Reader screenshots are readable;
  Settings bitmap capture renders its background black, so Settings acceptance
  uses live native geometry assertions rather than that image's label colors.
- A separate Mac XCUI runner was rejected by Gatekeeper. Removed the temporary
  runner/target/task; no security policy or service was bypassed.
- Final actual LOTR default/small-text pagination and chrome tests passed 2/2
  on the exact SE, zero failures/skips, with `clippedLineCount=0` initially and
  after page turns/chrome toggles. Advanced raw offset 365 restored after both
  chrome round trips. Command: `IOS_SIMULATOR_UDID=C66CCB36-C43E-4174-861E-2FA713389C84 IOS_TESTS=EpubToMp3UITests/RealBookReaderUITests/testActualLOTRReaderPaginationAndChrome,EpubToMp3UITests/RealBookReaderUITests/testActualLOTRSmallTextPaginationAndChrome mise run ios:simulator:smoke:test`.
  Result: `.reports/simulator-smoke-F36D447A-D5C1-4914-9243-D02BBE225130/tests.xcresult`;
  log: `/tmp/page-turn-settings-lotr-final.log`; exported probe attachments:
  `/tmp/page-turn-settings-lotr-evidence`. The real-book test disables animation
  overlays to isolate pagination/chrome; the 17 focused tests separately verify
  live overlays, spine/destination transforms, chapter boundaries and glyph masks.
- `mise run ios:simulator:resume` relaunched the current installed app and left
  only the required SE open on LOTR Contents, page 1/5. Final screenshot:
  `/tmp/page-turn-settings-se-delivery.png`. Mac exited before SE startup.
- `mise run preflight`, `mise run hooks:reader-check` and owned staged
  `git diff --cached --check` passed. Unrelated `.ai-jail`
  and `.ai-memory.toml` are preserved outside delivery.
- No audio deliberately played. Local Python/Ruff, broad Rust tests, remote CI
  monitoring and PR/merge are outside this scoped verification.
