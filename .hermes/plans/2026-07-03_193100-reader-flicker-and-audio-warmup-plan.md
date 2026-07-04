# Reader flicker + audio-warmup banner implementation plan

> For Hermes: use subagent-driven-development skill to implement this plan task-by-task.

Goal: eliminate the chapter-change/page-counter/UI flicker on iPhone and replace the misleading embedded-audio warmup message path without changing the manual conversion flow.

Architecture: treat these as two separate iOS-only regressions. For the flicker, keep the existing fixed-layout pagination invariants and stabilize the reader/player handoff so chapter swaps do not temporarily publish stale chapter/page state into chrome. For the warmup issue, narrow the embedded-runtime warmup state so BookOpenView never surfaces a fake “still warming” blocker when the iOS direct-Edge path is effectively already ready, while leaving remote/manual conversion untouched.

Tech stack: SwiftUI, XCTest source-contract tests, xcodebuild macOS-host tests, physical iPhone validation.

---

## Problem summary

Observed on device:
1. Changing chapter causes visible flicker in page counter and surrounding UI.
2. The app still shows an “audio engine still warming” / warmup-derived status path that the user wants fixed.
3. Constraint: do not change manual conversion behavior.

Important repo context already confirmed:
- `ReaderView` already contains anti-flicker machinery: `lastValidPages`, frozen chrome insets, chapter-swap notes, page-turn debounce, and source-contract tests in `ReaderChromeAutoHideTests.swift`.
- `InstantReaderView` owns the reader chrome and audio/reader synchronization.
- `BookOpenView.startAudioBootstrap(...)` uses `audioWarmup.start()` + `waitUntilReady()` only on the embedded path (`settings.useEmbeddedRuntime`).
- `AudioEngineWarmup.start()` on iOS currently sets `.warming -> .ready` immediately after a yield and does not perform real blocking initialization anymore.
- Therefore any lingering “warming” UX is likely a state/message propagation issue, not a real engine dependency.

---

## Track A — Fix chapter/page/UI flicker

### Hypothesis

The remaining flicker is not the old full repagination bug already guarded by `ReaderChromeAutoHideTests`, but a state handoff bug between:
- `InstantReaderView.currentChapterIndex`
- `ReaderView.currentPage`
- top/bottom chrome labels / counters
- `readerCoordinator`
- audio-follow chapter swaps

The likely failure mode is:
- chapter swap starts,
- `ReaderView` resets or normalizes page state correctly for text,
- but some outer UI reads transient old/new mixed state and briefly renders the wrong page count or chapter label.

### Files to inspect/change

Primary:
- `ios/EpubToMp3/EpubToMp3/Views/ReaderView.swift`
- `ios/EpubToMp3/EpubToMp3/Views/InstantReaderView.swift`
- possibly `ios/EpubToMp3/EpubToMp3/Views/PlayerReaderView.swift` if it mirrors any chapter/page UI from the snapshot during reader swaps

Tests:
- `ios/EpubToMp3/EpubToMp3Tests/ReaderChromeAutoHideTests.swift`
- add a new focused source-contract test file if the existing one becomes too crowded

### Implementation direction

1. Audit every place the visible page counter / chapter label is derived in paginated mode.
   - Identify whether the counter is based on live `currentPage` + live freshly-built `pages.count`, or whether it can render during a swap when pages are empty / stale / being replaced.
   - Ensure the UI reads an `effectivePages`/stable count path during chapter swaps, just like the rendered page body already falls back to `lastValidPages`.

2. Introduce one explicit “chapter swap in progress” contract for chrome/counter reads if one does not already exist at the `ReaderView` surface.
   - During swap, suppress transient counter updates until the new chapter’s pages stabilize.
   - Keep the visible counter on the last coherent old value or snap directly to the final new value; never show an intermediate 0/N or wrong chapter’s page count.

3. Verify `InstantReaderView` is not re-publishing chapter identity too early.
   - Check `compatOnChange` handlers around `snapshot`, `globalPlayer.firstSegmentReady`, `currentSentenceId`, chapter jumps, and `ReaderSearchOverlay` / TOC callbacks.
   - If `currentChapterIndex` is updated before the new page model is stable, gate the outward UI mirror until `ReaderView` has completed the swap.

4. Preserve existing no-repagination invariants.
   - Do not regress frozen chrome insets.
   - Do not reintroduce old “currentPage = 0 against old pages” behavior.
   - Do not drop `lastValidPages` fallback for page body rendering.

### Test plan for Track A

Add/extend source-contract tests to lock the intended fix:

1. A test that the page-counter path uses stable/effective pages during a swap, not raw transient `pages`.
2. A test that chapter-swap UI gating exists (for example a dedicated latch or stable counter helper).
3. Keep existing anti-flicker source-contract tests green.

Then run:
- `xcodebuild test -scheme EpubToMp3 -destination 'platform=macOS' -only-testing:EpubToMp3Tests/ReaderChromeAutoHideTests`
- any new targeted reader test class

Finally validate on device by reproducing chapter changes and confirming:
- no page-counter flash
- no surrounding chrome flicker
- no wrong intermediate chapter/page label

---

## Track B — Fix “audio engine still warming” path without touching manual conversion

### Hypothesis

The embedded path still advertises warmup state through `BookOpenView.statusBanner`, but `AudioEngineWarmup.start()` is now effectively immediate on iOS. So the user-visible “warming” blocker is stale UX coupling, not a necessary engine precondition.

Because manual conversion is out of scope, change only the embedded reader/listen flow.

### Files to inspect/change

Primary:
- `ios/EpubToMp3/EpubToMp3/EpubToMp3App.swift` (`AudioEngineWarmup`)
- `ios/EpubToMp3/EpubToMp3/Views/BookOpenView.swift`
- `ios/EpubToMp3/EpubToMp3/Views/RootView.swift` only if global badge copy/state must stay consistent

Tests:
- add/extend source-contract tests around `BookOpenView` and warmup wiring
- likely extend `BookOpenViewPriorityTests.swift` or add a dedicated warmup source-contract test file

### Implementation direction

1. Separate global app warmup badge semantics from embedded listen bootstrap semantics.
   - Keep the app-level warmup object if root wants to show readiness/progress.
   - But `BookOpenView.startAudioBootstrap()` should not surface a blocking “still warming” banner if `AudioEngineWarmup` is already non-blocking on iOS.

2. Replace the current double gate:
   - today: `if await audioWarmup.start() { guard await audioWarmup.waitUntilReady() else ... }`
   - target: a non-blocking best-effort readiness touch for embedded mode, followed immediately by `bootstrapEmbedded(...)`, unless there is a real failure state.

3. Keep the failure path only for true warmup failures.
   - If `audioWarmup.state == .failed(...)`, surface retry/error text.
   - If warmup is merely `.warming`, do not block listen bootstrap with a “still warming” message.

4. Do not modify remote/manual conversion behavior.
   - No changes to `/api/convert`
   - No changes to manual conversion tab/service flow
   - No changes to backend contract for this task

5. Update copy if needed.
   - If any banner still mentions “warming” in the listen flow, replace it with neutral generation progress (“Generating audio…”) unless there is a true failure.

### Test plan for Track B

Add/extend tests to prove:
1. `BookOpenView` no longer blocks embedded bootstrap on warmup-in-progress state.
2. `BookOpenView` still handles true warmup failure state explicitly.
3. Manual conversion source paths are untouched by this change.

Then run targeted Swift tests on macOS host.

---

## Ordered implementation tasks

### Task 1: capture the exact UI state sources for chapter/page counter
Objective: map the current counter/chrome derivation path before editing.

Files:
- Inspect `ReaderView.swift`
- Inspect `InstantReaderView.swift`

Steps:
1. Locate all computed props/views that render page number, total pages, chapter label, and any chapter-progress indicator.
2. Trace whether they use raw `paginationCache.pages`, `lastValidPages`, `currentPage`, or mirrored chapter state.
3. Note where a chapter-swap latch already exists and where chrome ignores it.

Verification:
- You can explain exactly why the counter can flicker even if the page body no longer does.

### Task 2: write failing source-contract test for stable counter during chapter swap
Objective: prove the counter path is currently not explicitly stabilized.

Files:
- Modify or add under `ios/EpubToMp3/EpubToMp3Tests/`

Steps:
1. Add a source-contract test that requires a stable/effective page-count helper or explicit swap gate in the counter rendering path.
2. Run the targeted test and confirm RED.

### Task 3: implement counter/chrome stabilization
Objective: make chapter swap publish coherent page/chapter UI only.

Files:
- Modify `ReaderView.swift`
- Possibly `InstantReaderView.swift`

Steps:
1. Add a stable helper/latch for counter reads.
2. Use it in the visible page counter / related chrome.
3. If needed, delay mirrored chapter publication until swap completion.
4. Keep existing anti-flicker machinery intact.

Verification:
- targeted Swift test passes
- existing reader anti-flicker tests still pass

### Task 4: write failing warmup source-contract test
Objective: prove embedded listen bootstrap should not block on non-failing warmup.

Files:
- add/extend test under `ios/EpubToMp3/EpubToMp3Tests/`

Steps:
1. Add a source-contract test that asserts `BookOpenView` does not gate embedded bootstrap behind `waitUntilReady()` as a blocking prerequisite, or otherwise asserts the new non-blocking contract.
2. Run targeted test and confirm RED.

### Task 5: implement non-blocking embedded warmup behavior
Objective: remove misleading warmup blocker from listen flow only.

Files:
- Modify `BookOpenView.swift`
- Possibly small supporting adjustment in `EpubToMp3App.swift` / `RootView.swift`

Steps:
1. Change embedded bootstrap to best-effort start warmup, but not block on `.warming`.
2. Preserve explicit failure handling.
3. Keep generic `Generating audio…` status in the listen flow.
4. Do not touch manual conversion flow.

Verification:
- targeted warmup test passes
- priority/bootstrap tests still pass

### Task 6: run regression suite
Objective: verify no regressions in the touched slice.

Run:
- targeted Swift tests for reader flicker and warmup/bootstrap
- existing tests:
  - `BookOpenViewPriorityTests`
  - `InstantReaderIndexMapperTests`
  - `TocDrawerTests`
  - `DownloadManagerHelperTests`
  - `ReaderChromeAutoHideTests`

### Task 7: physical-device validation
Objective: confirm both user-reported issues are gone.

Checks on iPhone:
1. change chapters repeatedly in the reader/player path
2. verify no page-counter/UI flicker
3. trigger listen bootstrap in embedded mode
4. verify no misleading “still warming” blocker appears
5. confirm manual conversion remains unchanged by not exercising or touching that flow in code

---

## Risks / guardrails

- Do not regress the previously-fixed chapter-crossing animation/wrong-page flash protections.
- Do not reintroduce live-height repagination on chrome toggle.
- Do not make the app-level warmup badge lie about a true failure state.
- Do not edit backend/manual conversion paths for the warmup fix.

---

## Definition of done

Done means all of the following are true:
- chapter changes no longer flicker page counter or adjacent UI on device
- embedded listen flow no longer surfaces the misleading warmup blocker
- manual conversion behavior/code path remains untouched
- targeted Swift tests pass
- device validation passes
