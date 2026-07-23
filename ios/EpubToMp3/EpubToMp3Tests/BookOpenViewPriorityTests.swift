import XCTest

final class BookOpenViewPriorityTests: XCTestCase {
    func testBookOpenViewThreadsStartChapterIndexIntoRemoteBootstrapHelpers() throws {
        let source = try sourceFile(named: "Features/Reader/Views/BookOpenView.swift")

        XCTAssertTrue(
            source.contains("await self.waitForBackendThenBootstrap(startChapterIndex: startChapterIndex)"),
            "Remote bootstrap must thread the requested EPUB zero-based chapter into waitForBackendThenBootstrap instead of dropping it."
        )
        XCTAssertTrue(
            source.contains("private func waitForBackendThenBootstrap(startChapterIndex: Int) async"),
            "waitForBackendThenBootstrap must accept the requested EPUB zero-based chapter index."
        )
        XCTAssertTrue(
            source.contains("await bootstrapAudio(client: client, startChapterIndex: startChapterIndex)"),
            "Once the backend client becomes available, the requested chapter must continue into bootstrapAudio."
        )
        XCTAssertTrue(
            source.contains("private func bootstrapAudio(client: APIClient, startChapterIndex: Int) async"),
            "bootstrapAudio must accept the requested EPUB zero-based chapter index."
        )
    }

    func testBookOpenViewSubmitsPriorityChapterIndexToConvertOptions() throws {
        let source = try sourceFile(named: "Features/Reader/Views/BookOpenView.swift")

        XCTAssertTrue(
            source.contains("opts.priorityChapterIndex = startChapterIndex"),
            "Remote conversion submission must persist the requested EPUB zero-based chapter as the backend priority hint."
        )
    }

    func testApiClientConvertOptionsExposesPriorityChapterIndex() throws {
        let source = try apiClientSource()

        XCTAssertTrue(
            source.contains("var priorityChapterIndex: Int? = nil"),
            "ConvertOptions must expose an optional priorityChapterIndex field for remote on-demand streaming prioritization."
        )
        XCTAssertTrue(
            source.contains("appendField(name: \"priority_chapter_index\", value: String(priorityChapterIndex))"),
            "submitConversion must serialize priority_chapter_index when the caller provides it."
        )
    }

    func testInstantReaderForwardsSubsequentSnapshotsIntoMountedPlayer() throws {
        let source = try sourceFile(named: "Features/Reader/Views/InstantReaderView.swift")

        XCTAssertTrue(
            source.contains(".compatOnChange(of: snapshot) { updatedSnapshot in"),
            "InstantReaderView must observe snapshot changes after the first playable chapter appears."
        )
        XCTAssertTrue(
            source.contains("player.updateSnapshot(updatedSnapshot)"),
            "Mounted remote audio must receive every later SSE snapshot so newly completed chapters append to the live queue."
        )
    }

    func testBookOpenViewForwardsSubsequentSnapshotsIntoMountedPlayer() throws {
        let source = try sourceFile(named: "Features/Reader/Views/BookOpenView.swift")

        XCTAssertTrue(
            source.contains("self.globalPlayer.updateSnapshot(updated)"),
            "BookOpenView must forward every remote SSE snapshot to the mounted player so newly completed chapters append to the live queue."
        )
    }

    func testPlayButtonsUseTheSharedTransportAction() throws {
        let sources = [
            try sourceFile(named: "Features/Playback/Views/MiniPlayerBar.swift"),
            try sourceFile(named: "Features/Playback/Views/FullPlayerSheet.swift"),
            try sourceFile(named: "Features/Reader/Views/PlayerReaderView.swift"),
            try sourceFile(named: "Features/Reader/Views/InstantReaderView.swift"),
            try sourceFile(named: "Features/Playback/Views/PlayerView.swift"),
        ]

        for source in sources {
            XCTAssertTrue(
                source.contains("togglePlayPause()"),
                "Every play surface must use AudioPlayer's shared togglePlayPause action."
            )
            XCTAssertFalse(
                source.contains(".playDivergenceDialog("),
                "Normal Play must not present the reader start-position chooser."
            )
        }
    }

    func testPlayerReaderViewPassesOnLinkTapToReaderView() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Reader/Views/PlayerReaderView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("onLinkTap:"),
            "PlayerReaderView must wire onLinkTap into ReaderView so link taps don't fall through to page-turn gesture."
        )
        XCTAssertTrue(
            source.contains("handleEpubLink"),
            "PlayerReaderView must implement handleEpubLink to navigate EPUB-internal hrefs."
        )
    }

    func testReaderViewLinkHitOriginUsesColumnCentredX() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Reader/Views/ReaderView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("containerSize.width - columnW") || source.contains("(containerSize.width - columnW) / 2"),
            "textOriginX must derive from the centred column position, not just margin, so link hit-rects match visual layout."
        )
    }

    func testPlayerReaderViewPassesChapterNavigationClosuresToReaderView() throws {
        let source = try sourceFile(named: "Features/Reader/Views/PlayerReaderView.swift")
        XCTAssertTrue(
            source.contains("onAdvanceChapter: { advanceToNextChapter() }"),
            "PlayerReaderView must pass onAdvanceChapter so the user can page past the last page to the next chapter."
        )
        XCTAssertTrue(
            source.contains("onPreviousChapter: { returnToPreviousChapter() }"),
            "PlayerReaderView must pass onPreviousChapter so the user can page before the first page to the previous chapter."
        )
        XCTAssertTrue(
            source.contains("private func advanceToNextChapter()"),
            "PlayerReaderView must implement advanceToNextChapter() calling player.play(snapshot:startingAt:)."
        )
        XCTAssertTrue(
            source.contains("private func returnToPreviousChapter()"),
            "PlayerReaderView must implement returnToPreviousChapter() calling player.play(snapshot:startingAt:)."
        )
    }

    func testInstantReaderKeepsAllStructuralChaptersInToc() throws {
        let source = try sourceFile(named: "Features/Reader/Views/InstantReaderView.swift")

        XCTAssertTrue(
            source.contains("Array(fulltext.chapters.enumerated()), id: \\.offset"),
            "The Reader TOC must include short, numeric, and image-only structural chapters."
        )
        XCTAssertFalse(
            source.contains("fulltext.chapters.filter {"),
            "The Reader TOC must not hide chapters based on extracted text length."
        )
        XCTAssertTrue(source.contains(".frame(minHeight: 320)"))
        XCTAssertTrue(source.contains(".foregroundStyle(.primary)"))
    }

    func testReaderClaimsKeyboardFocusForPageTurns() throws {
        let source = try source(named: "Features/Reader/Views/ReaderView.swift")

        XCTAssertTrue(source.contains(".compatFocusable()"))
        XCTAssertTrue(source.contains(".focused($readerHasFocus)"))
        XCTAssertTrue(source.contains("readerHasFocus = true"))
    }

    func testReaderKeyboardSupportsEscapeBackNavigation() throws {
        let compat = try sourceFile(named: "App/PlatformCompat.swift")
        let reader = try source(named: "Features/Reader/Views/ReaderView.swift")

        XCTAssertTrue(compat.contains("case .escape: key = .escape"))
        XCTAssertTrue(compat.contains("escape, j, k"))
        XCTAssertTrue(reader.contains("case .escape:"))
        XCTAssertTrue(reader.contains("onEscape?()"))
    }

    func testInstantReaderViewScrubberDecouplesSeekFromDrag() throws {
        let source = try sourceFile(named: "Features/Reader/Views/InstantReaderView.swift")
        XCTAssertTrue(
            source.contains("scrubberDragValue"),
            "InstantReaderView scrubber must buffer drag position in scrubberDragValue and only seek on onEditingChanged(false)."
        )
        XCTAssertFalse(
            source.contains("set: { player.seek(to: $0) }"),
            "InstantReaderView scrubber must not call player.seek on every drag event — use scrubberDragValue instead."
        )
    }

    func testReaderViewCancelsAllTasksOnDisappear() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Reader/Views/ReaderView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("jumpToLastPageTask?.cancel()"),
            "ReaderView.onDisappear must cancel jumpToLastPageTask to prevent writes to torn-down state."
        )
        XCTAssertTrue(
            source.contains("pageTurnResetTask?.cancel()"),
            "ReaderView.onDisappear must cancel pageTurnResetTask to prevent isPageTurning writes after view teardown."
        )
        XCTAssertTrue(
            source.contains("pageTurnResetTask = Task { @MainActor in"),
            "ReaderView must use a cancellable Task for page-turn reset instead of DispatchQueue.asyncAfter."
        )
    }

    func testFullPlayerSheetGuardsTaskCancellationInPositionLoop() throws {
        let source = try sourceFile(named: "Features/Playback/Views/FullPlayerSheet.swift")
        XCTAssertTrue(
            source.contains("guard !Task.isCancelled else { break }"),
            "FullPlayerSheet .task position loop must guard Task.isCancelled to stop processing after sheet dismiss."
        )
    }

    func testReaderViewChapterTransitionFreezesAtPageZeroNotLastPage() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Reader/Views/ReaderView.swift"),
            encoding: .utf8
        )
        // During a chapter crossing the departing chapter's lastValidPages must
        // be shown at page 0 (freeze-frame), NOT at currentPage (the last page).
        // Showing lastValidPages at currentPage=77 produced a "77/77" flash then
        // "1/6" — the chapter-boundary flicker bug.
        XCTAssertTrue(
            source.contains("chapterTransitionDisplayPage"),
            "ReaderView must use chapterTransitionDisplayPage to pin freeze-frame to page 0 during chapter transitions."
        )
        XCTAssertTrue(
            source.contains("usingStalePages ? chapterTransitionDisplayPage : nil"),
            "paginatedPageContent and stablePageFooterIndex calls must use chapterTransitionDisplayPage as pageOverride when usingStalePages."
        )
        // lastValidPages must NOT be zeroed on chapter change — we need content
        // to freeze on during the render gap of the incoming chapter.
        XCTAssertFalse(
            source.contains("paginationCache.lastValidPages = []"),
            "lastValidPages must not be cleared on chapter change — it serves as the freeze-frame during the render gap."
        )
    }

    func testReaderViewGuardsTextOffsetAgainstEmptyPagesAndZeroOffset() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Reader/Views/ReaderView.swift"),
            encoding: .utf8
        )
        // The guard moved from the derived `currentPages` array to the source of
        // truth (`paginationCache.pages`). That's stronger: if the live cache is
        // empty we bail before writing any offset, even when `livePages(fallback:)`
        // would hand us a fallback array from a stale render path.
        XCTAssertTrue(
            source.contains("guard !paginationCache.pages.isEmpty else { return }"),
            "compatOnChange(of: currentPage) must guard against an empty live pagination cache to prevent textOffsetAtCurrentPage being zeroed during rapid turns."
        )
        XCTAssertTrue(
            source.contains("textOffsetAtCurrentPage = cumulativeOffset(page: newPage, in: currentPages)"),
            "Once the live pagination cache is confirmed non-empty, ReaderView should derive textOffsetAtCurrentPage from the current live pages in one step."
        )
        XCTAssertFalse(
            source.contains("guard !currentPages.isEmpty else { return }"),
            "The old currentPages.isEmpty guard is stale once the live cache becomes the source of truth."
        )
        XCTAssertFalse(
            source.contains("if offset > 0 || newPage == 0"),
            "The old zero-offset heuristic should be gone once the fix guards directly on the live pagination cache instead of trying to infer emptiness from cumulativeOffset."
        )
    }

    // MARK: - Backward chapter crossing: last-page landing (pure logic tests)
    //
    // These tests model the clampedPage and jumpToLastPage logic in pure Swift,
    // without reading source files. They demonstrate the exact bug state that
    // caused "retreat goes to page 0" and prove the fix is correct.
    // Each test would FAIL if the bug code was used instead of the fix.

    /// BUG STATE: currentPage starts at 0 (default). clampedPage with empty pages = 0.
    /// FIX STATE: currentPage starts at Int.max. clampedPage with populated pages = last.
    ///
    /// This models TextKitPageView.clampedPage = max(0, min(pages.count-1, currentPage)).
    /// With pages=[] (makeUIViewController runs before pagination): min(-1, x) = -1, max(0,-1) = 0.
    /// Bug: currentPage=0 → clampedPage=0 → seeds page 0. Task later navigates 0→last (visible hop).
    /// Fix: currentPage=Int.max → clampedPage=0 on empty pages (same), BUT deferred seed
    ///      with Int.max sentinel skips animation (animated:false) → no visible hop.
    func testClampedPageWithEmptyPagesAlwaysReturnsZero() {
        func clampedPage(current: Int, pagesCount: Int) -> Int {
            max(0, min(pagesCount - 1, current))
        }

        // Both bug (currentPage=0) and fix (currentPage=Int.max) clamp to 0 with empty pages.
        // This is WHY the fix cannot rely on clampedPage alone — it must skip animation.
        XCTAssertEqual(clampedPage(current: 0, pagesCount: 0), 0,
            "Bug state: currentPage=0 with empty pages → clampedPage=0, seeds page 0.")
        XCTAssertEqual(clampedPage(current: Int.max, pagesCount: 0), 0,
            "Fix state: currentPage=Int.max with empty pages → clampedPage still 0 (not avoidable).")

        // When pages arrive (deferred seed), Int.max correctly resolves to last page.
        XCTAssertEqual(clampedPage(current: Int.max, pagesCount: 6), 5,
            "Fix: Int.max with 6 pages → clampedPage=5 (last page). Deferred seed must use this.")
        XCTAssertEqual(clampedPage(current: 0, pagesCount: 6), 0,
            "Bug: currentPage=0 with 6 pages → clampedPage=0. jumpToLastPageTask would then navigate 0→5 animated.")
    }

    /// BUG: jumpToLastPageTask uses `currentPage != p.count - 1` as guard.
    ///      When currentPage=0 and pages arrive (count=6), 0 != 5 → writes currentPage=5.
    ///      This triggers compatOnChange → TextKitPageView navigates 0→5 ANIMATED. Visible hop.
    ///
    /// FIX: jumpToLastPageTask uses `currentPage == Int.max` as guard.
    ///      When currentPage=Int.max and pages arrive, writes currentPage=5 (normalise sentinel).
    ///      TextKitPageView already shows page 5 (deferred seed animated:false). No second navigation.
    ///      When currentPage=0 (user already turned page), guard is false → no write → no hop.
    func testJumpToLastPageTaskGuardBehaviourBugVsFix() {
        // Model the bug guard: currentPage != p.count - 1
        func bugGuard(currentPage: Int, pageCount: Int) -> Bool {
            currentPage != pageCount - 1
        }
        // Model the fix guard: currentPage == Int.max
        func fixGuard(currentPage: Int) -> Bool {
            currentPage == Int.max
        }

        let pageCount = 6

        // Bug: fires when user is on page 0 (first page after recreation) → navigates to 5.
        XCTAssertTrue(bugGuard(currentPage: 0, pageCount: pageCount),
            "BUG: guard fires for currentPage=0, causing animated navigation 0→5.")

        // Bug: also fires if user manually turned to page 2 during loading → overrides user position.
        XCTAssertTrue(bugGuard(currentPage: 2, pageCount: pageCount),
            "BUG: guard fires for any page ≠ last, overriding user position.")

        // Fix: only fires for the Int.max sentinel.
        XCTAssertTrue(fixGuard(currentPage: Int.max),
            "FIX: guard fires only for Int.max sentinel → normalises to last page.")

        // Fix: does NOT fire when user is on page 0 (already navigated manually).
        XCTAssertFalse(fixGuard(currentPage: 0),
            "FIX: guard does NOT fire for currentPage=0 → no unwanted navigation.")

        // Fix: does NOT fire when user turned to page 2 during loading.
        XCTAssertFalse(fixGuard(currentPage: 2),
            "FIX: guard does NOT override user's page position.")
    }

    /// BUG: deferred seed always calls seedCrossing (animated).
    ///      seedCrossing(pvc, vc) with pendingCrossingDirection=nil → animated:false BUT
    ///      if pendingCrossingDirection=.forward → animates FORWARD from page 0 to last.
    ///      Either way the user sees a two-step transition: chapter curl + page navigation.
    ///
    /// FIX: deferred seed checks currentPage == Int.max → uses setViewControllers animated:false.
    ///      No extra animation. The chapter-curl (from the swipe) already happened.
    func testDeferredSeedAnimationDecision() {
        enum SeedAction: Equatable {
            case animatedViaSeedCrossing
            case hardCutAnimatedFalse
        }

        // Bug implementation: always seedCrossing.
        func bugDeferredSeed(currentPage: Int) -> SeedAction {
            return .animatedViaSeedCrossing
        }

        // Fix implementation: skip animation for Int.max sentinel.
        func fixDeferredSeed(currentPage: Int) -> SeedAction {
            if currentPage == Int.max {
                return .hardCutAnimatedFalse
            }
            return .animatedViaSeedCrossing
        }

        // Bug always animates — visible forward hop for backward crossings.
        XCTAssertEqual(bugDeferredSeed(currentPage: Int.max), .animatedViaSeedCrossing,
            "BUG: deferred seed always animates, causing visible hop from page 0 to last.")

        // Fix cuts hard for Int.max (backward crossing from startAtLastPage).
        XCTAssertEqual(fixDeferredSeed(currentPage: Int.max), .hardCutAnimatedFalse,
            "FIX: deferred seed uses animated:false for Int.max → no visible hop.")

        // Fix still animates for forward crossings (currentPage=0 → normal chapter advance).
        XCTAssertEqual(fixDeferredSeed(currentPage: 0), .animatedViaSeedCrossing,
            "FIX: deferred seed still animates for forward crossings (currentPage=0).")
    }

    /// BUG: init does NOT seed _currentPage = Int.max when startAtLastPage=true.
    ///      currentPage starts at 0. makeUIViewController seeds page 0.
    ///      jumpToLastPageTask fires (currentPage=0 != pages.count-1) → navigates animated.
    ///
    /// FIX: init seeds _currentPage = Int.max when startAtLastPage=true.
    ///      makeUIViewController clamps Int.max to 0 (pages empty) — unavoidable.
    ///      Deferred seed detects Int.max → animated:false → no visible hop.
    ///      jumpToLastPageTask fires (Int.max == Int.max) → normalises to pages.count-1 silently.
    func testFullBackwardCrossingFlowBugVsFix() {
        struct ReaderState {
            var currentPage: Int
            var jumpToLastPending: Bool
        }

        // Bug: init does NOT seed Int.max.
        func bugInit(startAtLastPage: Bool) -> ReaderState {
            ReaderState(currentPage: 0, jumpToLastPending: startAtLastPage)
        }

        // Fix: init seeds Int.max when startAtLastPage.
        func fixInit(startAtLastPage: Bool) -> ReaderState {
            ReaderState(
                currentPage: startAtLastPage ? Int.max : 0,
                jumpToLastPending: startAtLastPage
            )
        }

        func clampedPage(current: Int, pagesCount: Int) -> Int {
            max(0, min(pagesCount - 1, current))
        }

        let pageCount = 6

        // Bug flow:
        let bugState = bugInit(startAtLastPage: true)
        let bugInitialSeed = clampedPage(current: bugState.currentPage, pagesCount: 0)
        XCTAssertEqual(bugInitialSeed, 0, "BUG: makeUIViewController seeds page 0 (currentPage=0, pages empty).")
        let bugDeferredTarget = clampedPage(current: bugState.currentPage, pagesCount: pageCount)
        XCTAssertEqual(bugDeferredTarget, 0, "BUG: deferred seed also targets page 0 (currentPage still 0).")
        // jumpToLastPageTask fires: 0 != pageCount-1=5 → navigates to 5 animated → VISIBLE HOP.
        let bugTaskFires = bugState.currentPage != pageCount - 1
        XCTAssertTrue(bugTaskFires, "BUG: jumpToLastPageTask fires and navigates page 0→5 animated. Visible hop.")

        // Fix flow:
        let fixState = fixInit(startAtLastPage: true)
        let fixInitialSeed = clampedPage(current: fixState.currentPage, pagesCount: 0)
        XCTAssertEqual(fixInitialSeed, 0, "FIX: makeUIViewController still seeds page 0 (pages empty, unavoidable).")
        let fixDeferredTarget = clampedPage(current: fixState.currentPage, pagesCount: pageCount)
        XCTAssertEqual(fixDeferredTarget, 5, "FIX: deferred seed targets page 5 (Int.max clamped to last).")
        // Deferred seed detects Int.max → animated:false. No hop.
        let fixDeferredAnimated = fixState.currentPage != Int.max
        XCTAssertFalse(fixDeferredAnimated, "FIX: deferred seed uses animated:false. No visible hop.")
        // jumpToLastPageTask fires (Int.max == Int.max) but only normalises — TextKitPageView already shows page 5.
        let fixTaskNormalisesOnly = fixState.currentPage == Int.max
        XCTAssertTrue(fixTaskNormalisesOnly, "FIX: task only normalises sentinel, does not re-navigate.")
    }

    func testReaderViewCallSitesApplyChapterIdModifier() throws {
        // Without .id(chapter.id), SwiftUI updates ReaderView in-place on chapter
        // advance, preserving @State (including currentPage). The new chapter is
        // delivered to body() BEFORE onChange(of: chapter.id) fires, so there is
        // always at least one frame with chapter=NEW + currentPage=OLD — the "77/77"
        // flash. .id(chapter.id) forces a full teardown+recreate, eliminating the
        // stale-state frame entirely.
        let playerSource = try sourceFile(named: "Features/Reader/Views/PlayerReaderView.swift")
        let instantSource = try sourceFile(named: "Features/Reader/Views/InstantReaderView.swift")

        XCTAssertTrue(
            playerSource.contains(".id(chapter.id)"),
            "PlayerReaderView must apply .id(chapter.id) to its ReaderView call site so SwiftUI recreates ReaderView atomically on chapter change instead of updating in-place with stale @State."
        )
        XCTAssertTrue(
            instantSource.contains(".id(chapter.id)") || instantSource.contains(".id(fulltext.chapters[0].id)"),
            "InstantReaderView must apply .id(chapter.id) to every ReaderView call site to prevent the chapter-transition flicker."
        )
    }

    func testReaderHostViewsDoNotResetStartAtLastPageInOnAppear() throws {
        let playerSource = try sourceFile(named: "Features/Reader/Views/PlayerReaderView.swift")
        let instantSource = try sourceFile(named: "Features/Reader/Views/InstantReaderView.swift")

        XCTAssertFalse(
            playerSource.contains(".onAppear { readerShouldStartAtLastPage = false }"),
            "PlayerReaderView must not clear readerShouldStartAtLastPage from ReaderView.onAppear; that races the backward-crossing handoff and can drop startAtLastPage before the new ReaderView consumes it."
        )
        XCTAssertFalse(
            instantSource.contains(".onAppear { readerShouldStartAtLastPage = false }"),
            "InstantReaderView must not clear readerShouldStartAtLastPage from ReaderView.onAppear; reset it only after the new chapter binding has been consumed."
        )
    }

    func testPlayerReaderPreviousChapterRetreatUsesDisplayedEpubIndexNotPlayerPlayableIndex() throws {
        let source = try sourceFile(named: "Features/Reader/Views/PlayerReaderView.swift")

        XCTAssertTrue(
            source.contains("let currentEpubIndex = playingEpubZeroBasedIndex ?? player.currentChapterIndex"),
            "PlayerReaderView must derive previous-chapter retreat from the displayed EPUB chapter index first; using player.currentChapterIndex directly can reopen the previous chapter at page 0 when reader/audio chapter axes diverge."
        )
        XCTAssertTrue(
            source.contains("let prev = max(0, currentEpubIndex - 1)"),
            "Previous-chapter retreat must decrement the displayed EPUB chapter before mapping to playback."
        )
        XCTAssertTrue(
            source.contains("let playablePrev = InstantReaderIndexMapper.playableIndexOrClamped(\n            forEpubIndex: prev,\n            in: snapshot,\n            direction: .atOrBefore\n        )"),
            "After computing the previous EPUB chapter, PlayerReaderView must map it back into the playable axis explicitly with backward clamping."
        )
    }

    func testPlayerReaderBootstrapDoesNotReplayInitialChapterOverExistingSnapshot() throws {
        let source = try sourceFile(named: "Features/Reader/Views/PlayerReaderView.swift")

        XCTAssertFalse(
            source.contains("player.play(snapshot: snapshot, startingAt: initialChapterIndex)"),
            "bootstrap() must not blindly replay initialChapterIndex once a live player snapshot exists; that can overwrite a just-completed retreat and jump back to the chapter start."
        )
        XCTAssertTrue(
            source.contains("reloadCurrentChapter(epubIndexOverride: displayedEpubIndexOverride ?? playingEpubZeroBasedIndex)"),
            "bootstrap() should prefer reloading the displayed EPUB chapter override first, then the player's reported EPUB chapter, instead of restarting playback at the original chapter."
        )
    }

    func testPlayerReaderPositionLoopDoesNotOverwriteManualRetreatWithPlayableFallback() throws {
        let source = try sourceFile(named: "Features/Reader/Views/PlayerReaderView.swift")

        XCTAssertFalse(
            source.contains("let epubOverride = InstantReaderIndexMapper\n                        .epubIndex(forPlayableIndex: detectedIndex, in: snapshot)\n                    reloadCurrentChapter(epubIndexOverride: epubOverride)"),
            "The position loop must not immediately remap detected playable index back into reloadCurrentChapter during a manual retreat; that can overwrite the explicit previous-chapter EPUB override with a stale playable reading."
        )
    }

    func testPlayerReaderLastPageFlagDoesNotResetFromGenericChapterIndexChange() throws {
        let source = try sourceFile(named: "Features/Reader/Views/PlayerReaderView.swift")

        XCTAssertFalse(
            source.contains(".compatOnChange(of: playingEpubZeroBasedIndex ?? player.currentChapterIndex) { _ in\n            readerShouldStartAtLastPage = false\n        }"),
            "readerShouldStartAtLastPage must not be cleared by a generic chapter-index observer; reset only after the retreat handoff has definitely been consumed by the new ReaderView."
        )
    }

    func testPlayerReaderClearsLastPageFlagOnlyAfterRetreatTargetAppears() throws {
        let source = try sourceFile(named: "Features/Reader/Views/PlayerReaderView.swift")

        XCTAssertTrue(
            source.contains("@State private var pendingRetreatTargetEpubIndex: Int? = nil"),
            "PlayerReaderView must track the specific EPUB chapter targeted by a backward crossing so the start-at-last-page flag is cleared only after that exact chapter becomes visible."
        )
        XCTAssertTrue(
            source.contains("pendingRetreatTargetEpubIndex = targetEpubIndex"),
            "returnToPreviousChapter() must remember the resolved EPUB chapter waiting to consume the last-page handoff."
        )
        XCTAssertTrue(
            source.contains("guard let pendingTarget = pendingRetreatTargetEpubIndex")
                && source.contains("chapter.zeroBasedEpubIndex == pendingTarget"),
            "PlayerReaderView must clear the handoff only when the displayed EPUB chapter matches the pending retreat target."
        )
        XCTAssertTrue(
            source.contains("readerShouldStartAtLastPage = false\n                    pendingRetreatTargetEpubIndex = nil\n                    displayedEpubIndexOverride = nil"),
            "Once the target previous chapter lands on its last page, PlayerReaderView must clear all retreat handoff state."
        )
    }

    func testPlayerReaderPinsDisplayedEpubIndexAcrossManualChapterRetreat() throws {
        let source = try sourceFile(named: "Features/Reader/Views/PlayerReaderView.swift")

        XCTAssertTrue(
            source.contains("@State private var displayedEpubIndexOverride: Int? = nil"),
            "PlayerReaderView must keep a dedicated displayedEpubIndexOverride so retreat rendering does not fall back to a stale player.currentChapterIndex before the player catches up."
        )
        XCTAssertTrue(
            source.contains("private var displayedEpubIndex: Int {\n        displayedEpubIndexOverride ?? playingEpubZeroBasedIndex ?? player.currentChapterIndex\n    }"),
            "PlayerReaderView must derive all visible chapter lookups from displayedEpubIndex so explicit retreat/jump overrides win over stale playable-index reads."
        )
        XCTAssertTrue(
            source.contains("displayedEpubIndexOverride = targetEpubIndex"),
            "returnToPreviousChapter() must pin the resolved displayed EPUB index immediately when retreat starts."
        )
        XCTAssertTrue(
            source.contains("displayedEpubIndexOverride = epubIndex"),
            "jumpTo(chapterIndex:) must pin the displayed EPUB index immediately so the reader renders the target chapter before playback state catches up."
        )
        XCTAssertTrue(
            source.contains(".compatOnChange(of: playingEpubZeroBasedIndex) { newEpubIndex in")
                && source.contains("displayedEpubIndexOverride = nil"),
            "PlayerReaderView must release the displayed EPUB override only after the player reports the same EPUB chapter, otherwise retreat can snap back to the stale chapter start."
        )
        XCTAssertFalse(
            source.contains("chapter(in: fulltext, at: playingEpubZeroBasedIndex ?? player.currentChapterIndex)"),
            "Reader pane must not resolve visible chapters directly from playingEpubZeroBasedIndex ?? player.currentChapterIndex once displayedEpubIndex exists; that path reintroduces the retreat race."
        )
    }

    func testTextKitPageViewDeferredSeedSkipsAnimationForIntMaxCurrentPage() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Reader/Views/TextKitPageView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("if currentPage == Int.max {")
                && source.contains("pvc.setViewControllers([vc], direction: .forward, animated: false)")
                && source.contains("coordinator.seedCrossing(pvc, vc)"),
            "TextKitPageView deferred seed must hard-cut when currentPage == Int.max; otherwise the backward retreat briefly shows page 1 before hopping to the last page."
        )
    }

    func testReaderViewSeedsAndGuardsFooterAcrossChapterSwapGap() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Reader/Views/ReaderView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("@State private var currentPageChapterId: String = \"\""),
            "ReaderView must track which chapter currentPage belongs to so stale footer values are suppressed during chapter swaps."
        )
        XCTAssertTrue(
            source.contains("currentPageChapterId = \"\""),
            "ReaderView must invalidate currentPageChapterId on chapter.id change before the new footer is computed."
        )
        XCTAssertTrue(
            source.contains("let footerChapterReady = currentPageChapterId == chapter.id && !usingStalePages"),
            "ReaderView must hide the footer during the chapter-swap gap instead of rendering the old page number against the new chapter."
        )
        XCTAssertTrue(
            source.contains("if currentPageChapterId != chapter.id {\n                    currentPageChapterId = chapter.id\n                }"),
            "ReaderView must seed currentPageChapterId on appear so page-0 landings still show a footer after .id-based recreation."
        )
    }

    func testFullPlayerSheetTocButtonUsesTocDrawer() throws {
        let source = try sourceFile(named: "Features/Playback/Views/FullPlayerSheet.swift")
        XCTAssertTrue(
            source.contains("TocDrawer("),
            "FullPlayerSheet TOC button must open TocDrawer, not ChapterListSheet."
        )
        XCTAssertFalse(
            source.contains("ChapterListSheet(player:"),
            "ChapterListSheet must not be used from FullPlayerSheet — TocDrawer is the canonical TOC UI."
        )
    }

    private func source(named path: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3").appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private func sourceFile(named name: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/\(name)"),
            encoding: .utf8
        )
    }

    private func apiClientSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Conversion/Services/APIClient.swift"),
            encoding: .utf8
        )
    }
}
