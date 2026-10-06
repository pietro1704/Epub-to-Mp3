# Reader Chrome Tap Toggle Fix Implementation Plan

> For Hermes: execute task-by-task with specialist review before each implementation step.

Goal: make a non-link tap on the reader reliably toggle both top and bottom chrome on the real iPhone, without page turns; preserve horizontal swipe navigation and link interaction.

Architecture: identify the single active reader gesture path first, then centralize tap handling in one coordinator/callback. Avoid competing SwiftUI overlays and UIKit recognizers. Keep chrome state owned by the host (`InstantReaderView`/`PlayerReaderView`) and make the reader surface emit one semantic `onTap` event.

Tech stack: SwiftUI, UIKit `UITextView`, `UIPageViewController`, XcodeGen, XCTest, physical iPhone via `xcodebuild`/`devicectl`.

---

### Task 1: Confirm the active reader path on device

Files:
- Inspect: `ios/EpubToMp3/EpubToMp3/Views/ReaderView.swift`
- Inspect: `ios/EpubToMp3/EpubToMp3/Views/AttributedPageView.swift`
- Inspect: `ios/EpubToMp3/EpubToMp3/Views/TextKitPageView.swift`
- Inspect: `ios/EpubToMp3/EpubToMp3/Views/InstantReaderView.swift`
- Inspect: `ios/EpubToMp3/EpubToMp3/Views/PlayerReaderView.swift`

Steps:
1. Add temporary DEBUG logging at each tap entry point: `FixedWidthTextView.handleReaderTap`, `TextKitPageController.handlePageTap`, host `onCenterTap`, and chrome state mutation.
2. Build/install on the physical iPhone.
3. Tap center once and collect the event sequence.
4. Remove logging after the root path is confirmed.

Expected result: exactly one tap entry and exactly one `chromeVisible` transition per tap.

---

### Task 2: Add a failing source-contract test for one semantic tap

Files:
- Modify: `ios/EpubToMp3/EpubToMp3Tests/ReaderTapRoutingTests.swift`
- Test: `ios/EpubToMp3/EpubToMp3Tests/ReaderChromeAutoHideTests.swift`

Assertions:
- each active renderer has one tap recognizer path;
- no `tapZones` overlay competes with the native text/page view;
- `onCenterTap` reaches the host;
- `chromeVisible` is mutated exactly once;
- a simple tap does not call `advancePage`, `retreatPage`, `navigate`, `onAdvanceChapter`, or `onPreviousChapter`;
- horizontal swipe remains wired separately.

Run:
```bash
cd ios/EpubToMp3
xcodegen generate
xcodebuild -project EpubToMp3.xcodeproj -scheme EpubToMp3 \
  -destination 'platform=macOS,arch=x86_64' \
  -derivedDataPath ./.build-reader-tests \
  -only-testing:EpubToMp3Tests/ReaderTapRoutingTests \
  -only-testing:EpubToMp3Tests/ReaderChromeAutoHideTests test
```

Expected result: RED until the actual gesture path satisfies the contract.

---

### Task 3: Centralize the tap event

Files:
- Modify: `ios/EpubToMp3/EpubToMp3/Views/AttributedPageView.swift`
- Modify: `ios/EpubToMp3/EpubToMp3/Views/TextKitPageView.swift`
- Modify: `ios/EpubToMp3/EpubToMp3/Views/ReaderView.swift`

Implementation:
1. Keep link hit-testing first.
2. Emit one `onReaderTap`/`onCenterTap` event for every non-link tap.
3. Do not classify simple taps into left/center/right page zones.
4. Keep page/chapter navigation only in horizontal swipe callbacks and explicit buttons.
5. Ensure `UIGestureRecognizerDelegate` does not cause the same tap to be delivered twice.
6. For `UIPageViewController`, attach the recognizer to the correct visible container and ensure child `UITextView` recognizers do not duplicate it.

Expected result: one tap toggles chrome; no page index/chapter index mutation occurs.

---

### Task 4: Make host chrome transition deterministic

Files:
- Modify: `ios/EpubToMp3/EpubToMp3/Views/InstantReaderView.swift`
- Modify: `ios/EpubToMp3/EpubToMp3/Views/PlayerReaderView.swift`

Implementation:
1. Extract `toggleReaderChrome()` on the host.
2. Mutate the single `chromeVisible` state exactly once.
3. Ensure auto-hide/restore callbacks cannot immediately overwrite the tap result.
4. Verify both top and bottom bars use the same `chromeVisible` binding.
5. Keep safe-area insets synchronized with the same state.

Expected result: top and bottom bars appear/disappear together and remain in the new state after the animation completes.

---

### Task 5: Run RED/GREEN regression suite

Run:
```bash
cd ios/EpubToMp3
xcodegen generate
xcodebuild -project EpubToMp3.xcodeproj -scheme EpubToMp3 \
  -destination 'platform=macOS,arch=x86_64' \
  -derivedDataPath ./.build-reader-tests \
  -only-testing:EpubToMp3Tests/ReaderTapRoutingTests \
  -only-testing:EpubToMp3Tests/ReaderChromeAutoHideTests test
```

Expected result: all relevant tests pass; any intentionally skipped source-contract tests are documented separately.

---

### Task 6: Physical-device build and validation

Run:
```bash
cd ios/EpubToMp3
xcodegen generate
xcodebuild -project EpubToMp3.xcodeproj -scheme EpubToMp3 \
  -configuration Debug \
  -destination 'id=00008140-001128A022BA801C' \
  -derivedDataPath ./.build-device build
xcrun devicectl device install app \
  --device 44B2CFBD-2193-5086-8E8D-BF7A2876C321 \
  ./.build-device/Build/Products/Debug-iphoneos/EpubToMp3.app
xcrun devicectl device process launch \
  --device 44B2CFBD-2193-5086-8E8D-BF7A2876C321 \
  com.pietrocode.epubtomp3
```

Manual acceptance on iPhone:
- open the affected LOTR reader;
- tap center once: top and bottom chrome hide;
- tap center again: both reappear;
- tap over a link: link opens, chrome does not toggle;
- swipe left/right: page/chapter navigation works;
- repeat in the actual reader mode used by the report (scroll, slide, or curl).

Do not claim PASS from build/tests alone; the two-state tap behavior must be exercised on the physical iPhone.

---

### Task 7: Commit the focused fix

After physical acceptance:
```bash
git diff --check
git add ios/EpubToMp3/EpubToMp3/Views ios/EpubToMp3/EpubToMp3Tests docs/plans/2026-07-15-reader-chrome-tap-fix.md
git commit -m "fix(ios): toggle reader chrome from text taps"
```

Do not include unrelated widget/library changes in this commit.

---

## Specialist audit findings (2026-07-15)

The highest-probability root cause is duplicate tap delivery in `.pageCurl`:

- `TextKitPageView` installs a tap recognizer on `pvc.view` (`TextKitPageView.swift:111-120`).
- `TextKitPageController` installs another tap recognizer on its `UITextView` (`TextKitPageView.swift:782-789`).
- Both paths reach `onCenterTap`, and simultaneous recognition is allowed (`TextKitPageView.swift:682-683`).
- One physical tap can therefore call `chromeVisible.toggle()` twice, producing no visible state change.

Secondary findings to include in implementation:

- `ChromeVisibilityModifier` receives `visible` but currently does not use it to control system navigation/tab bars (`InstantReaderView.swift:1438-1458`).
- `PlayerReaderView` does not propagate `.readerChromeVisible(chromeVisible)` consistently.
- `onAutoHideChrome` and `onRestoreChrome` are declared and passed by hosts but are not invoked by the effective `ReaderView` gesture/page-turn flow.
- Scroll, slide/none, and page-curl have distinct gesture pipelines and must be validated independently.

Priority correction: first make page-curl have one tap owner, then verify host chrome state and system-bar synchronization. Do not rely only on source-contract tests; duplicate callbacks and visually unchanged toggles require physical-iPhone logs/screenshots.
