import SwiftUI
import os.log
#if os(iOS)
import AVKit
#endif

/// Full-screen split view: reader pane + compact transport controls.
///
/// Layout:
///   - Phone (compact horizontal): reader on top, transport on bottom.
///   - iPad landscape (regular horizontal): reader left, transport right.
///
/// Replaces the slice-2 `PlayerView` sheet. The audio player itself is
/// still owned by this view via `@State` so it lives for the duration
/// of the reader session.
struct PlayerReaderView: View {
    let snapshot: JobSnapshot
    let backendBaseURL: URL?
    var initialChapterIndex: Int = 0

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.dismiss) private var dismiss
    @State private var fulltextStore = FulltextStore()
    @State private var fulltext: EbookFulltext?
    @State private var fulltextError: String?
    @State private var isLoadingFulltext: Bool = true

    @State private var sync = SyncEngine()
    @State private var spans: [SentenceSpan] = []
    /// Set to true just before a backward chapter crossing so the
    /// new ReaderView (created via .id change) starts at its last page.
    /// Cleared only after the chapter cursor has changed, so the new
    /// ReaderView init can consume the flag first.
    @State private var readerShouldStartAtLastPage = false
    /// EPUB chapter index currently waiting to consume the backward-crossing
    /// "start at last page" handoff. Cleared only when that exact chapter is
    /// visible so unrelated player/index churn cannot drop the handoff early.
    @State private var pendingRetreatTargetEpubIndex: Int? = nil
    /// EPUB chapter index the UI should render immediately after a manual
    /// jump/retreat, before AudioPlayer's playable-index cursor has caught up.
    /// Released once `playingEpubZeroBasedIndex` reports the same chapter.
    @State private var displayedEpubIndexOverride: Int? = nil
    @State private var currentSentenceId: String?

    @State private var showingToc = false
    @State private var lastLoadedChapterIndex: Int = -1
    @State private var positionTask: Task<Void, Never>?
    @State private var sentenceTask: Task<Void, Never>?
    @State private var fulltextTask: Task<Void, Never>?
    @State private var streamTask: Task<Void, Never>?
    /// JobId currently being streamed by `streamTask`. Used to
    /// short-circuit re-subscription when `bootstrap()` is called
    /// again for the same job (state-restoration, scene activation,
    /// sheet re-present) — re-opening SSE for an already-streaming
    /// job tears down and rebuilds the same backend connection for
    /// no behavioural benefit.
    @State private var streamingJobId: String?
    /// Last time the SSE stream re-triggered a fulltext load because the
    /// text hadn't arrived yet. Debounces the auto-retry so a burst of
    /// chapter-progress snapshots can't spam the fulltext endpoint.
    @State private var lastFulltextAutoRetryAt: Date = .distantPast
    /// Minimum gap between SSE-driven fulltext re-fetches. The retry ladder
    /// inside a single refresh() spans ~23 s; if the EPUB parse is still
    /// running when the ladder exhausts, the text stays in error until the
    /// user taps Retry. Re-arming from the live audio stream recovers it
    /// automatically once the parse finishes, without hammering the backend.
    private static let fulltextAutoRetryInterval: TimeInterval = 8
    /// Currently-running cover fetch. Stored as `@State` so
    /// `onDisappear` can cancel it — otherwise a fast Book A → Book B
    /// → Book A nav can land Book B's bytes on Book A's player
    /// (Task.detached doesn't pin the view).
    @State private var coverFetchTask: Task<Void, Never>?
    /// JobId the in-flight cover fetch was started for. We bail when
    /// the active snapshot changed before the bytes finished
    /// downloading, so the wrong book never gets the wrong cover.
    @State private var coverFetchJobId: String?
    @State private var downloadTask: Task<Void, Never>?
    @State private var downloadState: DownloadButtonState = .idle
    @State private var downloadProgressText: String?
    @State private var showingBookmarks = false
    @State private var showingSearch = false
    /// Immersive-reading toggle. Dimmed by page-turns; restored by a
    /// center-tap inside the reader pane.
    @State private var chromeVisible = true
    /// Sentence the user tapped — drives the sentence action menu.
    @State private var pendingSentence: SentenceSpan?
    @EnvironmentObject private var bookmarkStore: BookmarkStore

    @EnvironmentObject private var readerCoordinator: ReaderCoordinator
    private var readerChapterIndex: Int { readerCoordinator.anchor.chapterIndex }
    private var readerPageRatio: Double? { readerCoordinator.anchor.pageRatio }
    @State private var pendingAnchor: PlayDivergenceAnchor?
    /// See `FullPlayerSheet.scrubberDragValue` — decouples the slider
    /// thumb from `player.positionSeconds` while a drag is in flight
    /// so each pixel of movement doesn't post a seek to the asset
    /// playback queue.
    @State private var scrubberDragValue: TimeInterval?

    /// Tri-state for the toolbar Download button. `idle` is the default
    /// CTA; `downloading` shows a determinate progress label; `done`
    /// confirms completion until the next mount.
    enum DownloadButtonState: Equatable {
        case idle
        case downloading
        case done
        case failed
    }

    /// Shared download manager — chapter MP3s land in
    /// `<documents>/Audiobooks/<jobId>/chapters/` and survive offline.
    @State private var downloads = DownloadManager()

    var body: some View {
        rootView
        .overlay {
            if showingSearch, let ft = fulltext {
                ReaderSearchOverlay(
                    chapters: ft.chapters,
                    onJumpToChapter: { idx in jumpTo(chapterIndex: idx - 1) },
                    isPresented: $showingSearch
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showingSearch)
        .onAppear {
            guard !isSwiftUIPreview else { return }
            bootstrap()
        }
        .onDisappear(perform: teardown)
        // Defense-in-depth: every current parent forces a fresh view
        // identity on snapshot change via `.id(...)`, so `onAppear`
        // re-fires and `bootstrap()` runs against the new jobId.
        // A future caller that forgets the `.id(...)` would leave this
        // view mounted while `snapshot.jobId` mutates underneath us —
        // `positionTask` / `sentenceTask` would keep reading the OLD
        // player's streams, `streamingJobId` / `coverFetchJobId` would
        // stick to the previous job, and the UI would silently desync.
        // Tearing down and re-bootstrapping on jobId change keeps the
        // invariant local to this view instead of trusting every call
        // site to remember the identity key.
        .compatOnChange(of: snapshot.jobId) { _ in
            guard !isSwiftUIPreview else { return }
            teardown()
            bootstrap()
        }
        .compatOnChange(of: playingEpubZeroBasedIndex) { newEpubIndex in
            guard let newEpubIndex else { return }
            // Only clear the override for a non-retreat jump (TOC / advance)
            // here — the audio index catches up near-instantly, well before
            // this instance may still need `startAtLastPage: true` on a
            // retreat. Retreat's own reset happens in `onLastPageLanded`,
            // once the reader (not the player) confirms it landed.
            if displayedEpubIndexOverride == newEpubIndex, pendingRetreatTargetEpubIndex == nil {
                displayedEpubIndexOverride = nil
            }
        }
        .confirmationDialog(
            pendingSentence?.text ?? "",
            isPresented: Binding(
                get: { pendingSentence != nil },
                set: { if !$0 { pendingSentence = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let span = pendingSentence {
                Button(L10n.string("reader.sentenceMenu.playFromHere")) {
                    seekToSentence(span)
                    pendingSentence = nil
                }
                let isBookmarked = bookmarkStore.hasBookmark(
                    bookId: bookId, chapterIndex: player.currentChapterIndex
                )
                Button(
                    isBookmarked
                        ? L10n.string("reader.sentenceMenu.removeBookmark")
                        : L10n.string("reader.sentenceMenu.addBookmark")
                ) {
                    if isBookmarked {
                        if let bm = bookmarkStore
                            .bookmarks(for: bookId, chapterIndex: player.currentChapterIndex)
                            .first(where: { !$0.isHighlight }) {
                            bookmarkStore.remove(id: bm.id)
                        }
                    } else {
                        bookmarkStore.addBookmark(
                            bookId: bookId,
                            chapterIndex: player.currentChapterIndex,
                            chapterTitle: currentChapterTitle
                        )
                    }
                    pendingSentence = nil
                }
                Button(L10n.string("reader.sentenceMenu.cancel"), role: .cancel) {
                    pendingSentence = nil
                }
            }
        }
    }

    private var rootView: some View {
        CompatNavigationStack {
            Group {
                if hSize == .regular {
                    HStack(spacing: 0) {
                        readerPane
                        if chromeVisible {
                            Divider()
                            transportPane
                                .frame(maxWidth: 360)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        readerPane
                        if chromeVisible {
                            Divider()
                            transportPane
                                // minHeight prevents the pane from
                                // collapsing; no fixed ceiling so XXXL
                                // Dynamic Type can expand the title/scrubber.
                                .frame(minHeight: 180)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
            }
            .modifier(ChromeVisibilityModifier(visible: chromeVisible))
            .navigationTitle(snapshot.bookTitle ?? L10n.string("player.audiobookFallback"))
            .compatInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        player.pause()
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .accessibilityLabel(L10n.string("player.close"))
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    // Primary: TOC stays as the single most-used action.
                    Button { showingToc = true } label: {
                        Image(systemName: "list.bullet.indent")
                    }
                    .accessibilityLabel(L10n.string("player.toc"))

                    // Overflow menu — mirrors Apple Books / Music's
                    // `ellipsis.circle` pattern: keeps the hit-target
                    // count within HIG limits (≤3 toolbar buttons)
                    // without hiding functionality.
                    Menu {
                        Button {
                            showingSearch = true
                        } label: {
                            Label(L10n.string("player.search"), systemImage: "magnifyingglass")
                        }
                        Button {
                            showingBookmarks = true
                        } label: {
                            Label(L10n.string("player.bookmarks"), systemImage: "bookmark")
                        }
                        Divider()
                        sleepTimerMenuItems
                        Divider()
                        bookmarkToggleMenuItem
                        downloadMenuItem
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(L10n.string("player.more"))
                }
            }
            .sheet(isPresented: $showingBookmarks) {
                CompatNavigationStack {
                    BookmarksListView(
                        bookId: bookId,
                        onJumpToChapter: { idx in
                            showingBookmarks = false
                            jumpTo(chapterIndex: idx)
                        }
                    )
                    .environmentObject(bookmarkStore)
                }
                .compatPresentationDetents()
            }
            .sheet(isPresented: $showingToc) {
                // SOURCE OF TRUTH: TocDrawer compares against the EPUB-side
                // (zero-based, dense over `fulltext.chapters`) chapter
                // index. `AudioPlayer.currentChapterIndex` is an index into
                // the FILTERED `playableChapters` list and is wrong to
                // pass directly when audio skips unplayable chapters
                // (footnotes, image-only sections). Resolve via the
                // playable chapter's own `index` field, which carries the
                // original zero-based EPUB index.
                let playingEpubIndex = InstantReaderIndexMapper
                    .epubIndex(forPlayableIndex: player.currentChapterIndex, in: snapshot) ?? -1
                TocDrawer(
                    fulltext: fulltext,
                    snapshot: snapshot,
                    currentChapterIndex: playingEpubIndex,
                    onJump: jumpTo(chapterIndex:),
                    onDownload: downloadChapter(epubIndex:)
                )
                .compatPresentationDetents()
            }
        }
    }

    // MARK: Panes

    @ViewBuilder
    private var readerPane: some View {
        VStack(spacing: 0) {
            fallbackBanner
            readerPaneCore
        }
    }

    /// Banner above the reader content offering an accessibility-voice
    /// readout when the chapter MP3 isn't ready yet but the chapter
    /// text is on hand. Hidden when MP3 is ready or no text is loaded;
    /// also hidden once the fallback synthesizer is already speaking
    /// — the existing transport controls drive it from then on.
    @ViewBuilder
    private var fallbackBanner: some View {
        switch SpeechFallbackUI.offer(
            isFallbackActive: player.isUsingSpeechFallback,
            snapshot: player.snapshot ?? snapshot,
            chapterIndex: displayedEpubIndex,
            fulltext: fulltext,
            languageCode: (player.snapshot ?? snapshot).language
        ) {
        case .hidden, .active:
            EmptyView()
        case let .available(text, languageCode):
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2.bubble")
                    .foregroundStyle(.tint)
                Text(localized: "playerReader.fallbackOffer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button {
                    player.playFallbackSpeech(text: text, languageCode: languageCode)
                } label: {
                    Text(localized: "playerReader.fallbackOfferButton")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.regularMaterial)
        }
    }

    @ViewBuilder
    private var readerPaneCore: some View {
        if isLoadingFulltext && fulltext == nil {
            VStack(spacing: 16) {
                ProgressView()
                Text(localized: "playerReader.loadingText")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let fulltext, let chapter = chapter(in: fulltext, at: displayedEpubIndex) {
            ReaderView(
                chapter: chapter,
                spans: spans,
                currentSentenceId: currentSentenceId,
                onJumpToSentence: jumpToSentence,
                onAdvanceChapter: { advanceToNextChapter() },
                onPreviousChapter: { returnToPreviousChapter() },
                onCenterTap: {
                    withAnimation(.easeInOut(duration: 0.25)) { chromeVisible.toggle() }
                },
                chromeVisible: chromeVisible,
                onAutoHideChrome: {
                    guard chromeVisible else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { chromeVisible = false }
                },
                onRestoreChrome: {
                    guard !chromeVisible else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { chromeVisible = true }
                },
                onLinkTap: { url in handleEpubLink(url) },
                onLastPageLanded: {
                    guard let pendingTarget = pendingRetreatTargetEpubIndex,
                          chapter.zeroBasedEpubIndex == pendingTarget else { return }
                    readerShouldStartAtLastPage = false
                    pendingRetreatTargetEpubIndex = nil
                    displayedEpubIndexOverride = nil
                },
                startAtLastPage: readerShouldStartAtLastPage
            )
            .id(chapter.id)
        } else if let err = fulltextError {
            VStack(spacing: 12) {
                Label(err, systemImage: "exclamationmark.triangle")
                    .multilineTextAlignment(.center)
                    .padding()
                Button(L10n.string("common.retry")) {
                    fulltextError = nil
                    isLoadingFulltext = true
                    triggerFulltextLoad()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(localized: "playerReader.noText")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var transportPane: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text(currentChapterTitle)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let author = snapshot.bookAuthor, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            scrubber
            transport
        }
        // 20pt vertical + horizontal margin, with the horizontal axis
        // sitting on top of any safe-area inset so the scrubber thumb
        // and transport buttons never cross the notch in landscape.
        .compatHorizontalSafeAreaPadding(20)
        .padding(.vertical, 20)
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { scrubberDragValue ?? player.positionSeconds },
                    set: { scrubberDragValue = $0 }
                ),
                in: 0...max(player.durationSeconds, 1),
                onEditingChanged: { editing in
                    #if os(iOS)
                    let generator = UIImpactFeedbackGenerator(style: editing ? .light : .medium)
                    generator.impactOccurred()
                    #endif
                    if !editing, let target = scrubberDragValue {
                        player.seek(to: target)
                        scrubberDragValue = nil
                    }
                }
            )
            HStack {
                Text(format(seconds: player.positionSeconds))
                Spacer()
                Text(format(seconds: player.durationSeconds))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 32) {
            Button { handlePlayTap() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 56))
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            }
            .accessibilityLabel(player.isPlaying ? L10n.string("player.pause") : L10n.string("player.play"))

            Button { player.nextChapter() } label: {
                Image(systemName: "forward.end.fill").font(.title2)
            }
            .accessibilityLabel(L10n.string("player.nextChapter"))

            transportMoreMenu
        }
        .tint(.primary)
        .frame(maxWidth: .infinity)
        .playDivergenceDialog(player: player, anchor: $pendingAnchor)
    }

    private func handlePlayTap() {
        switch player.playTapDecision(
            readerChapterIndex: readerChapterIndex,
            readerPageRatio: readerPageRatio
        ) {
        case .pause, .resume:
            player.togglePlayPause()
        case .offerStartChoice:
            pendingAnchor = .capture(from: readerCoordinator)
        }
    }

    /// "..." menu mirroring FullPlayerSheet — speed, sleep timer,
    /// secondary skip controls. Keeps the inline row to three taps.
    private var transportMoreMenu: some View {
        Menu {
            Menu {
                ForEach(PlaybackRate.allCases) { rate in
                    Button {
                        player.setRate(rate)
                    } label: {
                        if player.rate == rate {
                            Label(rate.shortLabel, systemImage: "checkmark")
                        } else {
                            Text(rate.shortLabel)
                        }
                    }
                }
            } label: {
                Label(
                    L10n.string("player.playbackSpeed", player.rate.shortLabel),
                    systemImage: "speedometer"
                )
            }
            Menu {
                ForEach([0, 5, 15, 30, 45, 60], id: \.self) { minutes in
                    Button {
                        if minutes == 0 {
                            player.setSleepTimer(seconds: 0)
                        } else {
                            player.startSleepTimer(minutes: minutes)
                        }
                    } label: {
                        if minutes == 0 {
                            Label(L10n.string("player.sleepTimerOption.off"), systemImage: "xmark")
                        } else {
                            Text(L10n.string("player.sleepTimerOption.\(minutes)"))
                        }
                    }
                }
            } label: {
                Label(L10n.string("player.sleepTimer"), systemImage: "moon.zzz")
            }
            Divider()
            Button { player.previousChapter() } label: {
                Label(L10n.string("player.previousChapter"), systemImage: "backward.end.fill")
            }
            Button { player.skipBackward(seconds: 15) } label: {
                Label(L10n.string("player.skipBack15"), systemImage: "gobackward.15")
            }
            Button { player.skipForward(seconds: 15) } label: {
                Label(L10n.string("player.skipForward15"), systemImage: "goforward.15")
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.title2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(L10n.string("player.more"))
    }

    /// Inline rate button: shows current rate; tapping cycles to the next one.
    private var rateButton: some View {
        Button { player.cycleRate() } label: {
            Text(player.rate.shortLabel)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    /// Compact badge showing sleep timer countdown. Hidden when inactive.
    @ViewBuilder
    private var sleepTimerBadge: some View {
        if player.sleepTimerRemaining > 0 {
            Button { player.cancelSleepTimer() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "moon.zzz.fill")
                    Text(formatSleepTimer(player.sleepTimerRemaining))
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
    }

    /// Overflow-menu Download row — fans out the snapshot's chapter MP3s
    /// to `DownloadManager` so the audiobook survives offline. Hidden
    /// when there's no resolvable backend URL or the snapshot carries
    /// no playable chapters.
    @ViewBuilder
    private var downloadMenuItem: some View {
        if backendBaseURL != nil, !snapshot.playableChapters.isEmpty {
            Button {
                startDownload()
            } label: {
                switch downloadState {
                case .idle:
                    Label(L10n.string("player.downloadAll"), systemImage: "arrow.down.circle")
                case .downloading:
                    Label(
                        downloadProgressText.map { "\(L10n.string("player.downloading")) \($0)" }
                            ?? L10n.string("player.downloading"),
                        systemImage: "arrow.down.circle"
                    )
                case .done:
                    Label(L10n.string("player.downloaded"), systemImage: "checkmark.circle.fill")
                case .failed:
                    Label(L10n.string("player.downloadFailed"), systemImage: "exclamationmark.circle")
                }
            }
            .accessibilityIdentifier("player.downloadAll")
            .disabled(downloadState == .downloading)
        }
    }

    private var bookId: String {
        library.books.first(where: { $0.lastJobId == snapshot.jobId })?.id ?? snapshot.jobId
    }

    /// Overflow-menu Bookmark toggle row.
    @ViewBuilder
    private var bookmarkToggleMenuItem: some View {
        let isBookmarked = bookmarkStore.hasBookmark(bookId: bookId, chapterIndex: player.currentChapterIndex)
        Button {
            if isBookmarked {
                if let bm = bookmarkStore.bookmarks(for: bookId, chapterIndex: player.currentChapterIndex)
                    .first(where: { !$0.isHighlight }) {
                    bookmarkStore.remove(id: bm.id)
                }
            } else {
                bookmarkStore.addBookmark(
                    bookId: bookId,
                    chapterIndex: player.currentChapterIndex,
                    chapterTitle: currentChapterTitle
                )
            }
        } label: {
            Label(
                isBookmarked ? L10n.string("player.removeBookmark") : L10n.string("player.addBookmark"),
                systemImage: isBookmarked ? "bookmark.fill" : "bookmark"
            )
        }
    }

    /// Kick off the download fan-out and stream the progress states back
    /// into `downloadState` / `downloadProgressText`.
    private func startDownload() {
        downloadTask?.cancel()
        downloadState = .downloading
        downloadProgressText = nil
        let jobId = snapshot.jobId
        downloadTask = Task { @MainActor in
            await downloads.enqueueAll(snapshot: snapshot, baseURL: backendBaseURL)
            for await progress in await downloads.watchProgress(jobId: jobId) {
                if Task.isCancelled { break }
                downloadProgressText =
                    "\(progress.completedChapters)/\(progress.totalChapters)"
                switch progress.state {
                case .completed:
                    downloadState = .done
                    if var book = library.books.first(where: { $0.lastJobId == snapshot.jobId }) {
                        book.cachedOffline = true
                        library.update(book)
                    }
                    return
                case .failed:
                    downloadState = .failed
                    return
                case .queued, .downloading, .paused:
                    downloadState = .downloading
                }
            }
        }
    }

    private func downloadChapter(epubIndex: Int) {
        guard backendBaseURL != nil,
              TocDrawer.downloadableChapter(forEpubZeroBasedIndex: epubIndex, in: snapshot) != nil else {
            return
        }
        downloadTask?.cancel()
        downloadState = .downloading
        downloadProgressText = nil
        let jobId = snapshot.jobId
        downloadTask = Task { @MainActor in
            await downloads.enqueueSelected(
                snapshot: snapshot,
                epubZeroBasedIndices: [epubIndex],
                baseURL: backendBaseURL
            )
            for await progress in await downloads.watchProgress(jobId: jobId) {
                if Task.isCancelled { break }
                downloadProgressText =
                    "\(progress.completedChapters)/\(progress.totalChapters)"
                switch progress.state {
                case .completed:
                    downloadState = .done
                    if var book = library.books.first(where: { $0.lastJobId == snapshot.jobId }) {
                        book.cachedOffline = true
                        library.update(book)
                    }
                    return
                case .failed:
                    downloadState = .failed
                    return
                case .queued, .downloading, .paused:
                    downloadState = .downloading
                }
            }
        }
    }

    /// Sleep timer rows rendered as direct children of the overflow Menu.
    /// Apple HIG nests Menus only when required for grouping — flattening
    /// these into the parent keeps the gesture count to one tap.
    @ViewBuilder
    private var sleepTimerMenuItems: some View {
        Section {
            Button {
                player.cancelSleepTimer()
            } label: {
                Label(L10n.string("player.sleepTimerOption.off"), systemImage: "moon.slash")
            }
            Button { player.startSleepTimer(minutes: 5) } label: {
                Label(L10n.string("player.sleepTimerOption.5"), systemImage: "moon")
            }
            Button { player.startSleepTimer(minutes: 15) } label: {
                Label(L10n.string("player.sleepTimerOption.15"), systemImage: "moon")
            }
            Button { player.startSleepTimer(minutes: 30) } label: {
                Label(L10n.string("player.sleepTimerOption.30"), systemImage: "moon")
            }
            Button { player.startSleepTimer(minutes: 60) } label: {
                Label(L10n.string("player.sleepTimerOption.60"), systemImage: "moon.fill")
            }
        } header: {
            Text(L10n.string("player.sleepTimer"))
        }
    }

    // MARK: Bootstrap

    private func bootstrap() {
        player.backendBaseURL = backendBaseURL
        if player.snapshot?.jobId != snapshot.jobId {
            player.updateSnapshot(snapshot)
        }
        reloadCurrentChapter(epubIndexOverride: displayedEpubIndexOverride ?? playingEpubZeroBasedIndex)
        triggerFulltextLoad()
        subscribeToJobStream()

        // Drive SyncEngine from the player's position stream.
        positionTask?.cancel()
        positionTask = Task { @MainActor in
            for await pos in player.position {
                if Task.isCancelled { break }
                _ = sync.update(positionSeconds: pos)
                // Also reload spans when the chapter index changes.
                // Snapshot the index NOW before any other async work runs —
                // reconcileChapterIndexFromCurrentItem may update it between
                // the check and the reload, causing a stale-index reload.
                let detectedIndex = player.currentChapterIndex
                if detectedIndex != lastLoadedChapterIndex,
                   !readerShouldStartAtLastPage,
                   let displayedEpubIndex = playingEpubZeroBasedIndex,
                   let remappedEpubIndex = InstantReaderIndexMapper
                        .epubIndex(forPlayableIndex: detectedIndex, in: snapshot),
                   remappedEpubIndex == displayedEpubIndex {
                    reloadCurrentChapter(epubIndexOverride: displayedEpubIndex)
                }
            }
        }

        // Mirror the engine's sentence stream into local state so
        // ReaderView re-renders without needing to observe SyncEngine.
        sentenceTask?.cancel()
        sentenceTask = Task { @MainActor in
            for await id in sync.currentSentence {
                if Task.isCancelled { break }
                self.currentSentenceId = id
            }
        }
    }

    private func teardown() {
        positionTask?.cancel(); positionTask = nil
        sentenceTask?.cancel(); sentenceTask = nil
        fulltextTask?.cancel(); fulltextTask = nil
        streamTask?.cancel(); streamTask = nil; streamingJobId = nil
        coverFetchTask?.cancel(); coverFetchTask = nil; coverFetchJobId = nil
        downloadTask?.cancel(); downloadTask = nil
        // Reset so bootstrap() on the new jobId always calls reloadCurrentChapter,
        // even when the new book opens at the same numeric chapter index as the old one.
        lastLoadedChapterIndex = -1
    }

    /// Live-stream the backend's per-chapter progress and feed each
    /// new snapshot back to the AudioPlayer so newly-finished chapters
    /// get appended to the queue. This is what gives the user
    /// chapter-by-chapter streaming playback while the rest of the
    /// audiobook is still being synthesised.
    private func subscribeToJobStream() {
        guard let baseURL = backendBaseURL else { return }
        let jobId = snapshot.jobId
        // Already streaming this jobId? Bail — re-subscribing would
        // tear down the live connection just to rebuild the identical
        // one against the same backend endpoint.
        if streamingJobId == jobId, let existing = streamTask, !existing.isCancelled {
            return
        }
        streamTask?.cancel()
        streamingJobId = jobId
        let client = APIClient(baseURL: baseURL)
        streamTask = Task { @MainActor in
            do {
                for try await event in client.eventStream(jobId: jobId) {
                    if Task.isCancelled { break }
                    if let updated = APIClient.decodeSnapshot(from: event.rawPayload) {
                        player.updateSnapshot(updated)
                        fetchCoverIfNeeded(snapshot: updated, baseURL: baseURL)
                        retryFulltextIfStillPending(snapshot: updated)
                    }
                }
            } catch is CancellationError {
                // User dismissed the reader (streamTask?.cancel() in
                // bootstrap) — not a real error. The status sheet
                // would otherwise show a stale "conversion error"
                // banner the next time the user reopens.
                return
            } catch let urlErr as URLError where urlErr.code == .cancelled {
                return
            } catch {
                let message = error.localizedDescription
                Logger(subsystem: "com.pietrop.epubtomp3", category: "sse")
                    .error("SSE stream failed: \(message, privacy: .public)")
                player.recordConversionError(message)
            }
        }
    }

    private func fetchCoverIfNeeded(snapshot: JobSnapshot, baseURL: URL) {
        guard player.coverArtData == nil,
              let coverPath = snapshot.coverUrl,
              !coverPath.isEmpty else { return }
        let url: URL?
        if coverPath.lowercased().hasPrefix("http") {
            url = URL(string: coverPath)
        } else {
            url = URL(string: coverPath, relativeTo: baseURL)?.absoluteURL
        }
        guard let resolvedURL = url else { return }
        // Already fetching this same job's cover? Don't double-fire.
        if coverFetchJobId == snapshot.jobId, coverFetchTask?.isCancelled == false {
            return
        }
        coverFetchTask?.cancel()
        coverFetchJobId = snapshot.jobId
        let targetJobId = snapshot.jobId
        coverFetchTask = Task { [weak player] in
            guard let (data, _) = try? await URLSession.shared.data(from: resolvedURL),
                  !data.isEmpty,
                  !Task.isCancelled else { return }
            await MainActor.run {
                // Don't apply the bytes if the user navigated to a
                // different book while the fetch was in flight — the
                // active snapshot's jobId is the source of truth.
                guard player?.snapshot?.jobId == targetJobId else { return }
                player?.coverArtData = data
            }
        }
    }

    private func triggerFulltextLoad() {
        // Surface any disk copy immediately for offline use.
        if let cached = FulltextStore.loadFromDisk(jobId: snapshot.jobId) {
            self.fulltext = cached
            self.isLoadingFulltext = false
            reloadCurrentChapter()
        }
        guard let baseURL = backendBaseURL else {
            if fulltext == nil {
                fulltextError = "Configure the backend URL in Settings to download book text."
                isLoadingFulltext = false
            }
            return
        }
        fulltextTask?.cancel()
        fulltextTask = Task { @MainActor in
            do {
                let payload = try await fulltextStore.refresh(jobId: snapshot.jobId, baseURL: baseURL)
                self.fulltext = payload
                self.fulltextError = nil
                self.isLoadingFulltext = false
                reloadCurrentChapter()
            } catch {
                if self.fulltext == nil {
                    self.fulltextError = error.localizedDescription
                }
                self.isLoadingFulltext = false
            }
        }
    }

    /// Re-arm the fulltext load when a live SSE snapshot arrives but the
    /// reader text still hasn't loaded. Covers the race where the EPUB parse
    /// outlasts the retry ladder inside a single `refresh()`: the audio stream
    /// keeps flowing, so each new chapter-progress event nudges the text to
    /// try again until the parse completes — no manual Retry tap needed.
    /// Debounced and gated on a non-terminal job so it never spams the backend
    /// or fights an in-flight load.
    private func retryFulltextIfStillPending(snapshot updated: JobSnapshot) {
        let now = Date()
        let loadInFlight = (fulltextTask?.isCancelled == false)
        guard Self.shouldAutoRetryFulltext(
            hasFulltext: fulltext != nil,
            jobIsTerminal: updated.isTerminal,
            hasBackend: backendBaseURL != nil,
            loadInFlight: loadInFlight,
            now: now,
            lastRetryAt: lastFulltextAutoRetryAt,
            minInterval: Self.fulltextAutoRetryInterval
        ) else { return }
        lastFulltextAutoRetryAt = now
        isLoadingFulltext = true
        triggerFulltextLoad()
    }

    /// Pure decision for `retryFulltextIfStillPending`, extracted so it can be
    /// unit-tested without a live SSE stream or backend. Re-fetch only when the
    /// text hasn't loaded, the job is still running, a backend is configured,
    /// no load is already in flight, and the debounce window has elapsed.
    /// `nonisolated` so the synchronous test can call it (the View is
    /// @MainActor; this decision is pure and touches no view state).
    nonisolated static func shouldAutoRetryFulltext(
        hasFulltext: Bool,
        jobIsTerminal: Bool,
        hasBackend: Bool,
        loadInFlight: Bool,
        now: Date,
        lastRetryAt: Date,
        minInterval: TimeInterval
    ) -> Bool {
        guard !hasFulltext else { return false }
        guard !jobIsTerminal else { return false }
        guard hasBackend else { return false }
        guard !loadInFlight else { return false }
        return now.timeIntervalSince(lastRetryAt) >= minInterval
    }

    private func reloadCurrentChapter(epubIndexOverride: Int? = nil) {
        // Use the EPUB index, not the playable index — see
        // `playingEpubZeroBasedIndex`. Falls back to the playable
        // index if the snapshot was empty / out of bounds.
        // `epubIndexOverride` is passed by jumpTo so we don't race
        // against AudioPlayer.currentChapterIndex not yet reflecting
        // the new position when play(snapshot:startingAt:) returns.
        let epubIdx = epubIndexOverride ?? displayedEpubIndexOverride ?? playingEpubZeroBasedIndex ?? player.currentChapterIndex
        guard let fulltext, let chapter = chapter(in: fulltext, at: epubIdx) else {
            spans = []
            // Wipe any stale per-sentence timing in the player so the
            // divergence dialog's sentence-precise seek can't land on
            // a phantom offset from the previous chapter.
            player.setSentenceTiming([:], forChapterIndex: player.currentChapterIndex)
            return
        }
        let computed = chapter.splitSentences()
        spans = computed
        sync.load(chapter: chapter, chapterDurationSeconds: player.durationSeconds)
        // Inject the sync-engine's sentence-id → start-ms map into the
        // player. Keyed by the playable-chapter index because that's
        // the index space `startFromReaderPage` uses when looking up.
        let map: [String: Int] = sync.timing.reduce(into: [:]) { acc, entry in
            acc[entry.id] = entry.startMs
        }
        player.setSentenceTiming(map, forChapterIndex: player.currentChapterIndex)
        lastLoadedChapterIndex = player.currentChapterIndex
    }

    /// Advance to the next playable chapter from the reader's paginated view.
    /// Called by ReaderView.onAdvanceChapter when the user pages past the last page.
    @discardableResult
    private func advanceToNextChapter() -> Bool {
        FlickerProbe.shared.log("advanceToNextChapter CALLED currentChapterIndex=\(player.currentChapterIndex) readerShouldStartAtLastPage=\(readerShouldStartAtLastPage)")
        let next = player.currentChapterIndex + 1
        guard next < snapshot.playableChapters.count else { return false }
        // Defensively clear a retreat's last-page flags if the user advances
        // forward before `onLastPageLanded` fired (interrupting a retreat
        // mid-flight) — otherwise the NEXT chapter's ReaderView would wrongly
        // inherit `startAtLastPage: true` and seed Int.max on a forward turn.
        readerShouldStartAtLastPage = false
        pendingRetreatTargetEpubIndex = nil
        // Pin the reader to the chapter it just crossed into. The audio queue
        // may reconcile/synthesize ahead of the visible reader; its cursor is
        // not a safe source for the next backward tap.
        let targetEpubIndex = InstantReaderIndexMapper.epubIndex(
            forPlayableIndex: next, in: snapshot
        )
        displayedEpubIndexOverride = targetEpubIndex
        player.play(snapshot: snapshot, startingAt: next)
        reloadCurrentChapter(epubIndexOverride: targetEpubIndex)
        return true
    }

    /// Return to the previous playable chapter from the reader's paginated view.
    /// Called by ReaderView.onPreviousChapter when the user pages before the first page.
    @discardableResult
    private func returnToPreviousChapter() -> Bool {
        // The audio cursor may already be ahead of the reader due to queue
        // reconciliation/background synthesis. Retreat from the displayed
        // EPUB chapter, otherwise a tap from chapter 5/page 1 can skip it.
        let currentEpubIndex = displayedEpubIndex
        guard let target = InstantReaderIndexMapper.previousPlayableTarget(
            beforeDisplayedEpubIndex: currentEpubIndex, in: snapshot
        ) else { return false }
        let playablePrev = target.playableIndex
        // Resolve the EPUB index the READER should display from the same
        // playable index the AUDIO is about to land on — not the raw `prev`.
        // When `prev` itself is non-playable (cover/TOC/skipped chapter),
        // `.atOrBefore` walks `playablePrev` back to an EARLIER chapter than
        // `prev`. Using `prev` here showed the non-playable chapter's own
        // (often short/near-empty) fulltext instead of the chapter that's
        // actually playing — the reader landed on "page 1 of the wrong
        // chapter" instead of the last page of the true previous playable
        // one. Mirrors `advanceToNextChapter`'s `epubIndex(forPlayableIndex:)`
        // resolution (line 993) so display and playback always agree.
        let targetEpubIndex = target.epubIndex
        FlickerProbe.shared.log(
            "retreat currentEpub=\(currentEpubIndex) prev=\(currentEpubIndex - 1) playablePrev=\(playablePrev) targetEpubIndex=\(targetEpubIndex)"
        )
        // Arm the last-page flag BEFORE changing the chapter so the
        // new ReaderView (born via .id recreation) reads it from its
        // init and seeds jumpToLastPageForChapterId = "__pending__".
        readerShouldStartAtLastPage = true
        pendingRetreatTargetEpubIndex = targetEpubIndex
        displayedEpubIndexOverride = targetEpubIndex
        player.play(snapshot: snapshot, startingAt: playablePrev)
        reloadCurrentChapter(epubIndexOverride: targetEpubIndex)
        return true
    }

    /// `chapterIndex` here is the EPUB zero-based index emitted by
    /// `TocDrawer` / search overlay — NOT a playable-list index. We
    /// must translate before handing it to `AudioPlayer.play`.
    private func jumpTo(chapterIndex epubIndex: Int) {
        // Restore chrome so the user can see the new chapter in context
        // (otherwise an immersive jump looks like the action silently failed).
        withAnimation(.easeInOut(duration: 0.25)) { chromeVisible = true }
        let target = InstantReaderIndexMapper
            .playableIndexOrClamped(forEpubIndex: epubIndex, in: snapshot)
        displayedEpubIndexOverride = epubIndex
        player.play(snapshot: snapshot, startingAt: target)
        // Pass epubIndex directly — player.currentChapterIndex has not
        // yet updated when play() returns, so reloadCurrentChapter()
        // without an override would reload the old chapter.
        reloadCurrentChapter(epubIndexOverride: epubIndex)
    }

    /// Mirror of InstantReaderView.handleEpubLink — resolves an EPUB-internal
    /// href to a chapter and navigates there via jumpTo. External URLs
    /// (http/https/mailto) are left for iOS to open.
    private func handleEpubLink(_ url: URL) -> Bool {
        if let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" || scheme == "mailto" {
            return false
        }
        guard let ft = fulltext else { return false }
        let base = url.lastPathComponent
            .replacingOccurrences(of: ".xhtml", with: "")
            .replacingOccurrences(of: ".html", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let fragment = (url.fragment ?? "").lowercased()
        let needle = base.isEmpty ? fragment : base
        guard !needle.isEmpty else { return false }
        if let match = ft.chapters.first(where: { chapter in
            let name = (chapter.name ?? "").lowercased()
            return !name.isEmpty && (name.contains(needle) || needle.contains(name))
        }) {
            jumpTo(chapterIndex: max(0, match.index - 1))
            return true
        }
        return false
    }

    private func jumpToSentence(_ span: SentenceSpan) {
        pendingSentence = span
    }

    private func seekToSentence(_ span: SentenceSpan) {
        guard let entry = sync.timing.first(where: { $0.id == span.id }) else { return }
        let seconds = TimeInterval(entry.startMs) / 1000.0
        player.seek(to: seconds)
    }

    // MARK: Helpers

    /// Map the player's zero-based chapter index to the matching
    /// fulltext entry. Delegates to `InstantReaderIndexMapper` so the
    /// negative-index and empty-fulltext guards are unit-tested in
    /// one place instead of duplicated here and in InstantReaderView.
    private func chapter(in fulltext: EbookFulltext, at zeroBasedIndex: Int) -> EbookFulltext.Chapter? {
        InstantReaderIndexMapper.chapter(in: fulltext, atZeroBasedIndex: zeroBasedIndex)
    }

    /// Translate `AudioPlayer.currentChapterIndex` (which is an index
    /// into the FILTERED `playableChapters` list) to the corresponding
    /// EPUB zero-based chapter index. Returns `nil` when the snapshot
    /// has no playable chapters or the player is out of bounds — both
    /// of which collapse the highlight back to "no current chapter".
    /// SOURCE OF TRUTH for any view comparing chapter cursors.
    private var playingEpubZeroBasedIndex: Int? {
        InstantReaderIndexMapper
            .epubIndex(forPlayableIndex: player.currentChapterIndex, in: snapshot)
    }

    private var displayedEpubIndex: Int {
        displayedEpubIndexOverride ?? playingEpubZeroBasedIndex ?? player.currentChapterIndex
    }

    private var currentChapterTitle: String {
        if let fulltext, let ch = chapter(in: fulltext, at: displayedEpubIndex) {
            return ch.displayTitle
        }
        let chapters = snapshot.playableChapters
        // Defensive both-sides bounds check: the player's index is
        // clamped on assignment, but if the snapshot shrinks (e.g. the
        // backend wipes a job mid-session) `player.currentChapterIndex`
        // can momentarily point past the new array, and any path that
        // ever pushed a negative index into the player would crash here.
        guard chapters.indices.contains(player.currentChapterIndex) else { return "—" }
        return chapters[player.currentChapterIndex].displayTitle
    }

    private func format(seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// Compact "4:59" countdown for the sleep timer badge.
    private func formatSleepTimer(_ remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded()))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

#if DEBUG
#Preview("PlayerReader") {
    PlayerReaderView(
        snapshot: JobSnapshot.previewSample,
        backendBaseURL: URL(string: "http://localhost:8000")
    )
    .environmentObject(AppSettings())
    .environmentObject(AudioPlayer())
    .environmentObject(LibraryStore.previewPopulated)
    .environmentObject(BookmarkStore.previewPopulated)
}
#endif
