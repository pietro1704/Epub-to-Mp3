# Reader: black flash on forward chapter-boundary page turns

**Status:** static-analysis diagnosis only. No device instrumentation was run. Confirm with `FlickerProbe.shared` counters (`.emptyPagesShown`, `.spuriousRenavigation`, `.staleSlicePushed`) on-device before implementing a fix.

## Scope confirmed by user
Black flash occurs specifically on **forward** page turns that cross a chapter boundary (last page of chapter N → first page of chapter N+1), and is reported to *recur on every subsequent page turn* within the new chapter, not just the crossing itself.

## Files examined
- `ios/EpubToMp3/EpubToMp3/Views/ReaderView.swift` (2073 lines)
- `ios/EpubToMp3/EpubToMp3/Views/PlayerReaderView.swift` (1141 lines, referenced only)
- `ios/EpubToMp3/EpubToMp3/Views/TextKitPageView.swift` (836 lines)

## Sequence of events, forward crossing (curl/PVC mode)

1. User taps the right third of the last page of chapter N → `Coordinator.handleTap` → `navigate(.forward, in:)`, `TextKitPageView.swift:414-477`.
2. Inside `navigate`, `candidate = current.pageIndex + 1` exceeds `parent.pages.count` → takes the chapter-crossing branch, `TextKitPageView.swift:436-448`:
   - `parent.onAdvanceChapter?()` is called (host-owned; bumps `chapter` in `ReaderView`/`PlayerReaderView`).
   - On success: `pendingCrossingDirection = .forward` (line 445) and **`isAwaitingChapterSwap = true`** (line 446).
   - Returns immediately — no `setViewControllers` call from this path.
3. `ReaderView.compatOnChange(of: chapter.id)` fires (`ReaderView.swift:408-474`): resets `currentPage = 0` (line 419, since `wantsLastPage` is false for a forward crossing), clears `currentPageChapterId`, `renderedAttributed = nil`, `paginationCache.key = nil`, `paginationCache.pages = []`, but **keeps `paginationCache.lastValidPages`** (comment at 441-446).
4. `.task(id: renderedAttributedKey)` (line 475) re-parses HTML → `renderedAttributed` (50-500ms, main-thread WebKit importer).
5. Body re-evaluates with `pages.isEmpty == true` (new chapter not yet paginated) and `lastValidPages` non-empty (still holding chapter N's page 0, per the freeze-frame design at `ReaderView.swift:943-953`). `effectivePages = lastValidPages`, `usingStalePages = true`. **This path is NOT empty and does not itself produce a black frame** — `FlickerProbe.emptyPagesShown` would only fire if `lastValidPages` were also empty (`ReaderView.swift:961-965`), which it isn't on a forward crossing following any successful earlier render.
6. `TextKitPageView.updateUIViewController` receives the update. `chapterToken != oldToken` is true → enters the token-swap branch (`TextKitPageView.swift:152-178`):
   - `coordinator.purgePool()`, `committedChapterToken = nil`.
   - `if !pages.isEmpty` — **at this instant `pages` (i.e. `paginationCache.pages`, NOT `lastValidPages`) is still `[]`** (cleared in step 3, not yet repopulated). So this branch's inner `if` is **false**, and control falls through to `return` at line 177 **without calling `seedCrossing` and without committing the token.** `isAwaitingChapterSwap` stays `true` (never explicitly cleared here — only implicitly via the later branch).
7. Once pagination finishes for chapter N+1, `pages` becomes non-empty and SwiftUI re-invokes `updateUIViewController` (triggered by the `@Binding var pages` change). Now `chapterToken == oldToken` still (same swap, no new token change happened in between) but `coordinator.committedChapterToken != chapterToken` (never committed in step 6) **and** `!pages.isEmpty` → enters the deferred-seed branch, `TextKitPageView.swift:184-209`.
   - `currentPage` is `0` (not `Int.max`, forward crossing) → takes the **`seedCrossing` animated branch** (line 207), NOT the hard-cut branch (line 200-201, which is backward-only).
8. `seedCrossing` (`TextKitPageView.swift:388-410`): `pendingCrossingDirection` is `.forward` (armed in step 2, never consumed in between since step 6 exited before reaching `seedCrossing`) → animates `pvc.setViewControllers([vc], direction: .forward, animated: true)`. This is a **genuine `UIPageViewController` page-curl animation**, and the "next" controller (`vc`) is built from `coordinator.controller(for: target)` — `target = clampedPage = currentPage (0)`, which is correct content (chapter N+1 page 0). However, the **currently displayed controller (the "back of the curl")** is whatever was last seeded into the PVC — from step 2's `navigate()`, nothing was ever pushed to the PVC (it returned early), so the PVC is still showing **chapter N's actual last page** (not a freeze-frame — the real `TextKitPageController` instance from before the tap). The curl animates from chapter N's last page directly to chapter N+1's page 0. This itself should not be black.

## Where the black frame most plausibly comes from — ranked hypotheses

### Hypothesis 1 (highest confidence): `isAwaitingChapterSwap` stuck across the SwiftUI render gap
Between step 6 (early return, latch still armed) and step 7 (deferred seed), **every SwiftUI body re-evaluation of `ReaderView`** re-renders `TextKitPageView` with `pages == []` still possible for multiple frames (pagination is async and can take multiple runloop turns for long chapters). During this whole window, `isAwaitingChapterSwap == true`. This is consumed only by `navigate()` (`TextKitPageView.swift:424`, guards user-taps) and is otherwise **inert** for `updateUIViewController` itself — meaning it does not cause black frames directly. **But**: nothing in the traced code ever explicitly sets it back to `false` except the top of the token-swap branch (`TextKitPageView.swift:153`) and the deferred-seed branch (`TextKitPageView.swift:192`) — both of which only run when a **new update fires**. If chapter N+1 has a **very short** first "page" or pagination briefly produces an empty array (e.g. a degenerate 0-page state during recompute — not verified in this pass, `PaginationEngine`/pagination source wasn't opened), the deferred-seed branch's `!pages.isEmpty` guard (line 184) could keep failing indefinitely, meaning the PVC never receives a new `setViewControllers` call and keeps showing chapter N's stale last page — **not black, but wrong-chapter**, which contradicts the "black" report. This weakens (not eliminates) hypothesis 1 as the sole cause; needs pagination-source review (out of scope for the files read).

### Hypothesis 2 (highest confidence for the black color specifically): `effectivePages` is right, but the **displayed `TextKitPageController`** briefly has no applied slice
`coordinator.controller(for: target)` (`TextKitPageView.swift:348-369`) pulls from `pool[index]` or builds fresh, then calls `vc.apply(slice:...)`. This happens synchronously in Swift, so the vended controller does have content by the time `setViewControllers` is called. However `seedCrossing`'s animated path (line 404) hands the **not-yet-installed** `vc` to `UIPageViewController` for a *curl* transition; `UIPageViewController`'s curl effect renders BOTH the outgoing and incoming controller's views layered/peeled during the animation. If `vc.view` has not yet undergone a layout pass (no `viewDidLayoutSubviews`/no frame set — first time this controller shell is used post-purge, since `purgePool()` was called in step 6), the incoming page can render as an empty/transparent view for the first several animation frames before layout catches up — **this reads as "black" specifically on the dark/black themes** documented in project memory `feedback_diagnose_audio_engine.md`-adjacent notes (see `.background(themeBackground)` at `ReaderView.swift:399` — an unlaid-out `UITextView` shows the SwiftUI-composited black/dark theme background underneath with no text, i.e. a black flash). This matches the "next1-black-next2-black" pattern because **`purgePool()` runs on every single token-swap branch entry** (line 154), and if pool churn / cold layout happens once per crossing but the SAME symptom recurring on subsequent *ordinary* in-chapter turns immediately after is unexplained by this alone — see Hypothesis 3.

### Hypothesis 3 (explains recurrence on subsequent normal turns): `committedChapterToken` race causes a SECOND uncommitted swap
If step 7's deferred-seed branch's `guard !coordinator.isTransitioning else { return }` (line 190) fires **while the animated curl from a previous crossing is still in flight** (`isTransitioning` was just set `true` by `seedCrossing` itself at line 402), any further SwiftUI-driven `updateUIViewController` calls during that ~"animated: true" duration (curl animations run several hundred ms) will hit the `count changed` branch (line 214) or the tail `guard current.pageIndex != target` (line 250) with **stale assumptions about `coordinator.isTransitioning`** — since `isTransitioning` is only cleared in `seedCrossing`'s own completion handler (line 406), a rapid subsequent tap (user tapping quickly through several pages right after landing in the new chapter, which is exactly what "black-next-black-next" suggests — a user tapping repeatedly) can be swallowed by `navigate()`'s `guard !isTransitioning` (line 425) turning into silent no-ops, OR — if the tap lands in the small window after `isTransitioning` clears but before SwiftUI has re-rendered with the correct `currentPage` — `updateUIViewController`'s final animated re-navigation (line 274) fires with a `vc` built from a **pool entry that was purged and rebuilt with a fresh, not-yet-laid-out view** (same cold-layout mechanism as Hypothesis 2), reproducing the black flash on each subsequent turn. This is consistent with the user's literal description ("next1-black-next2-black... alternate on subsequent regular page turns AFTER the crossing too").

## `renderedAttributedKey` re-entrancy (point 5) — RESOLVED, ruled out
Full body confirmed at `ReaderView.swift:271-288`:
```swift
private var renderedAttributedKey: String {
    let s = settings
    return [
        chapter.id, s.readerFontFamily.rawValue, String(format: "%.0f", s.readerPointSize),
        s.readerTheme.rawValue, s.readerOverrideFontFamily.description, s.readerOverrideFontSize.description,
        s.readerOverrideColours.description, s.readerBoldOverride.description, s.readerSuppressItalic.description,
        String(format: "%.2f", s.readerLetterSpacing), String(format: "%.2f", s.readerWordSpacing),
        s.readerTextAlignment.rawValue,
    ].joined(separator: "|")
}
```
Only `chapter.id` + font/theme/spacing settings feed the key — nothing reads `currentPage`, `pageDirection`, or any state a page turn mutates. `.task(id: renderedAttributedKey)` cannot re-fire from an ordinary page turn, forward crossing included. **Point 5 is definitively not implicated.**

## What was NOT confirmed
- Whether `lastValidPages` itself is ever cleared before new pages land (point 2) — traced code shows it is deliberately preserved (`ReaderView.swift:441-446`, `943-953`) and no code path clearing it besides the natural overwrite at `paginationCache.lastValidPages = pages` (`ReaderView.swift:1395`) was found. This point of the bug report appears **not** to be the cause.
- Pagination engine internals (where `paginationCache.pages` is computed) were not opened; a transient empty-pages state during repagination of chapter N+1 was hypothesized but not confirmed.
- No `FlickerProbe` counter values were captured (would require running the app — explicitly out of scope here).

## Answers to the five specific questions
1. **`chapterTransitionDisplayPage` / `usingStalePages` stuck?** No evidence found — both are recomputed fresh every body evaluation from `pages.isEmpty` and `paginationCache.lastValidPages`, not cached flags. Not implicated.
2. **`effectivePages` genuinely empty?** No — `lastValidPages` is deliberately retained and only overwritten once new pages exist (`ReaderView.swift:1395`). Not implicated.
3. **Forward-path race in TextKitPageView with an empty/stale `pages` array + double-hop?** Yes — see step 6/7 and Hypotheses 1-2. The `isAwaitingChapterSwap`/`committedChapterToken` handshake creates exactly the two-hop pattern (early return while `pages` empty, then deferred animated seed later), and the deferred seed always uses `animated: true` via `seedCrossing`, which is where the cold-layout black frame likely originates.
4. **Same crossing-state causing every subsequent turn to be treated as a fresh chapter load?** Not literally — `chapterToken` doesn't change again. But **`isTransitioning`/`committedChapterToken` bookkeeping around the deferred seed (Hypothesis 3) can desync from the actual PVC state**, causing subsequent legitimate `navigate()` calls to re-trigger pool-purge-adjacent cold-layout paths without an actual new chapter token change — a related but distinct mechanism, not the exact one asked about.
5. **`.task(id:)` re-entrant/cancelled due to hidden `settings` dependency?** No — confirmed ruled out, full key body inspected (`ReaderView.swift:271-288`), no page-turn-mutable state feeds it.

## Recommended next step (not implemented — fix is out of scope)
Confirm Hypothesis 2/3 on-device by instrumenting `TextKitPageController.viewDidLayoutSubviews`/`apply(slice:)` timing relative to `seedCrossing`'s `setViewControllers(..., animated: true)` call, and check whether forcing a synchronous layout pass (`vc.view.layoutIfNeeded()`) before handing `vc` to `seedCrossing` (`TextKitPageView.swift:404`) eliminates the flash. Also re-verify `renderedAttributedKey`'s full dependency list before ruling out point 5.
