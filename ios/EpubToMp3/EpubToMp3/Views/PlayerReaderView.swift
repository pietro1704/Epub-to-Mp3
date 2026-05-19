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
    @State private var downloadTask: Task<Void, Never>?
    @State private var downloadState: DownloadButtonState = .idle
    @State private var downloadProgressText: String?
    @State private var showingBookmarks = false
    @State private var showingSearch = false
    /// Immersive-reading toggle. Dimmed by page-turns; restored by a
    /// center-tap inside the reader pane.
    @State private var chromeVisible = true
    @EnvironmentObject private var bookmarkStore: BookmarkStore

    @AppStorage(AudioPlayer.readerCurrentChapterIndexDefaultsKey)
    private var readerChapterIndex: Int = 0
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
            .navigationTitle(snapshot.bookTitle ?? "Audiobook")
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
                let playingEpubIndex: Int = {
                    let playable = snapshot.playableChapters
                    guard playable.indices.contains(player.currentChapterIndex) else { return -1 }
                    return playable[player.currentChapterIndex].index
                }()
                TocDrawer(
                    fulltext: fulltext,
                    snapshot: snapshot,
                    currentChapterIndex: playingEpubIndex,
                    onJump: jumpTo(chapterIndex:)
                )
                .compatPresentationDetents()
            }
        }
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
    }

    // MARK: Panes

    @ViewBuilder
    private var readerPane: some View {
        if isLoadingFulltext && fulltext == nil {
            VStack(spacing: 16) {
                ProgressView()
                Text("Loading book text…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let fulltext, let chapter = chapter(in: fulltext, at: playingEpubZeroBasedIndex ?? player.currentChapterIndex) {
            ReaderView(
                chapter: chapter,
                spans: spans,
                currentSentenceId: currentSentenceId,
                onJumpToSentence: jumpToSentence,
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
                }
            )
        } else if let err = fulltextError {
            VStack(spacing: 12) {
                Label(err, systemImage: "exclamationmark.triangle")
                    .multilineTextAlignment(.center)
                    .padding()
                Button("Retry") {
                    fulltextError = nil
                    isLoadingFulltext = true
                    triggerFulltextLoad()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("No text available for this chapter.")
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
        switch player.playTapDecision(readerChapterIndex: readerChapterIndex) {
        case .pause, .resume:
            player.togglePlayPause()
        case .offerStartChoice:
            pendingAnchor = .capture(readerChapterIndex: readerChapterIndex)
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
        if player.snapshot?.jobId != snapshot.jobId {
            player.backendBaseURL = backendBaseURL
            player.play(snapshot: snapshot, startingAt: initialChapterIndex)
        }
        triggerFulltextLoad()
        subscribeToJobStream()

        // Drive SyncEngine from the player's position stream.
        positionTask?.cancel()
        positionTask = Task { @MainActor in
            for await pos in player.position {
                if Task.isCancelled { break }
                _ = sync.update(positionSeconds: pos)
                // Also reload spans when the chapter index changes.
                if player.currentChapterIndex != lastLoadedChapterIndex {
                    reloadCurrentChapter()
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
        downloadTask?.cancel(); downloadTask = nil
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
        Task.detached(priority: .utility) {
            guard let (data, _) = try? await URLSession.shared.data(from: resolvedURL),
                  !data.isEmpty else { return }
            await MainActor.run { player.coverArtData = data }
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

    private func reloadCurrentChapter() {
        // Use the EPUB index, not the playable index — see
        // `playingEpubZeroBasedIndex`. Falls back to the playable
        // index if the snapshot was empty / out of bounds.
        let epubIdx = playingEpubZeroBasedIndex ?? player.currentChapterIndex
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

    /// `chapterIndex` here is the EPUB zero-based index emitted by
    /// `TocDrawer` / search overlay — NOT a playable-list index. We
    /// must translate before handing it to `AudioPlayer.play`.
    private func jumpTo(chapterIndex epubIndex: Int) {
        // Restore chrome so the user can see the new chapter in context
        // (otherwise an immersive jump looks like the action silently failed).
        withAnimation(.easeInOut(duration: 0.25)) { chromeVisible = true }
        let playable = snapshot.playableChapters
        let target = playable.firstIndex(where: { $0.index == epubIndex })
            ?? max(0, min(epubIndex, playable.count - 1))
        player.play(snapshot: snapshot, startingAt: target)
        reloadCurrentChapter()
    }

    private func jumpToSentence(_ span: SentenceSpan) {
        // If we have real timestamps, seek to the sentence's start.
        // Otherwise the WPM-estimated table still gives a useful seek.
        guard let entry = sync.timing.first(where: { $0.id == span.id }) else { return }
        let seconds = TimeInterval(entry.startMs) / 1000.0
        player.seek(to: seconds)
    }

    // MARK: Helpers

    /// Map the player's zero-based chapter index to the matching
    /// fulltext entry. The backend numbers fulltext chapters from 1
    /// while `chapterProgress` is zero-based; we offset accordingly.
    private func chapter(in fulltext: EbookFulltext, at zeroBasedIndex: Int) -> EbookFulltext.Chapter? {
        let target = zeroBasedIndex + 1
        return fulltext.chapters.first { $0.index == target }
            ?? (zeroBasedIndex < fulltext.chapters.count ? fulltext.chapters[zeroBasedIndex] : nil)
    }

    /// Translate `AudioPlayer.currentChapterIndex` (which is an index
    /// into the FILTERED `playableChapters` list) to the corresponding
    /// EPUB zero-based chapter index. Returns `nil` when the snapshot
    /// has no playable chapters or the player is out of bounds — both
    /// of which collapse the highlight back to "no current chapter".
    /// SOURCE OF TRUTH for any view comparing chapter cursors.
    private var playingEpubZeroBasedIndex: Int? {
        let playable = snapshot.playableChapters
        guard playable.indices.contains(player.currentChapterIndex) else { return nil }
        return playable[player.currentChapterIndex].index
    }

    private var currentChapterTitle: String {
        if let fulltext, let ch = chapter(in: fulltext, at: playingEpubZeroBasedIndex ?? player.currentChapterIndex) {
            return ch.displayTitle
        }
        let chapters = snapshot.playableChapters
        guard player.currentChapterIndex < chapters.count else { return "—" }
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
