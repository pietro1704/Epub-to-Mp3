import SwiftUI

/// Reader-first surface. The text is *always* visible — even before
/// any audio exists. When the backend produces chapter MP3s the
/// player block lights up at the bottom; until then the reader looks
/// like a plain ebook reader.
///
/// Why a new view instead of reusing `PlayerReaderView`?
/// `PlayerReaderView` was built around a `JobSnapshot` snapshot and
/// assumes audio is already playable. This view inverts that: text
/// is the spine, audio is an evolving optional layer.
struct InstantReaderView: View {
    let fulltext: EbookFulltext
    @Binding var snapshot: JobSnapshot?
    let statusBanner: String?
    let hasAudio: Bool
    let backendBaseURL: URL?
    let coverPNG: Data?
    let onRequestAudioRetry: () -> Void

    /// Called when the user opts into audio. The bookId is used by
    /// the parent (`BookOpenView`) to fire `startAudioBootstrap()`;
    /// `chapterIndex` + `sentenceId` tell it where to seek once the
    /// first chapter MP3 lands.
    /// - chapterIndex: 0-based chapter to start at.
    /// - sentenceId: optional sentence anchor inside that chapter
    ///   (from `SentenceSpan.id`). `nil` = start from chapter's
    ///   beginning.
    var onRequestPlay: ((Int, String?) -> Void)? = nil
    @ObservedObject var cacheManager: ChapterCacheManager

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var globalPlayer: AudioPlayer
    @Environment(\.horizontalSizeClass) private var hSize

    @State private var currentChapterIndex: Int = 0
    @StateObject private var player = AudioPlayer()
    /// Tracks whether `player` has been wired with a snapshot via
    /// `mountPlayerIfPossible()`. We can't make `player` itself
    /// optional under Combine — `@StateObject` requires a concrete
    /// instance for `objectWillChange` subscriptions to fire — so we
    /// gate the UI on this flag instead.
    @State private var playerMounted: Bool = false
    @State private var pendingAnchor: PlayDivergenceAnchor?
    @State private var sync = SyncEngine()
    @State private var spans: [SentenceSpan] = []
    @State private var currentSentenceId: String?
    @State private var positionTask: Task<Void, Never>?
    @State private var sentenceTask: Task<Void, Never>?
    @State private var showingToc = false
    @State private var showingSearch = false
    @State private var pendingPlayAnchor: SentenceSpan?  // sentence the user tapped → "Play from here"
    @State private var showingPlayMenu = false
    @State private var showingConversionStatus = false
    @State private var showingFullPlayer = false
    @State private var showingReaderSettings = false
    @State private var chromeVisible = true

    private var embeddedAudioReady: Bool {
        settings.useEmbeddedRuntime && globalPlayer.firstSegmentReady
    }

    private var showTransport: Bool {
        playerMounted || embeddedAudioReady
    }

    private var activePlayer: AudioPlayer {
        if embeddedAudioReady { return globalPlayer }
        return player
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // Custom in-view top bar. Replacing NavigationStack's nav bar
            // entirely because every attempt to drive that bar with
            // `.navigationTitle` + `.toolbar` + `.navigationBarHidden`
            // either failed to render or stuck hidden on iOS 16-18 under
            // our exact view hierarchy. A view-local HStack is
            // deterministic, animates with chromeVisible, and exposes the
            // three reader controls (search / settings / TOC) per the
            // user's brief.
            if chromeVisible {
                customTopBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if chromeVisible {
                VStack(spacing: 0) {
                    Divider()
                        .background(readerForeground.opacity(0.15))
                    idlePlayerBar
                        .frame(height: showTransport ? 0 : nil)
                        .opacity(showTransport ? 0 : 1)
                        .clipped()
                        .allowsHitTesting(!showTransport)
                        .padding(.vertical, showTransport ? 0 : 8)
                    playerBar
                        .frame(height: showTransport ? nil : 0)
                        .opacity(showTransport ? 1 : 0)
                        .clipped()
                        .allowsHitTesting(showTransport)
                        .disabled(!showTransport)
                        .padding(.vertical, showTransport ? 8 : 0)
                }
                .background(readerBackground.opacity(0.96))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .modifier(ChromeVisibilityModifier(visible: chromeVisible))
        .compatFullScreenCover(isPresented: $showingFullPlayer) {
            FullPlayerSheet()
                .environmentObject(globalPlayer)
        }
        .sheet(isPresented: $showingReaderSettings) {
            ReaderSettingsSheet()
                .environmentObject(settings)
        }
        .sheet(isPresented: $showingSearch) {
            ReaderSearchOverlay(
                chapters: fulltext.chapters,
                onJumpToChapter: { idx in currentChapterIndex = idx },
                isPresented: $showingSearch
            )
        }
        .background {
            Color.clear.allowsHitTesting(false)
                .sheet(isPresented: $showingToc) { tocSheet }
        }
        .background {
            Color.clear.allowsHitTesting(false)
                .sheet(isPresented: $showingConversionStatus) {
                    ConversionStatusSheet(
                        status: globalPlayer.conversionStatus,
                        bookTitle: fulltext.bookTitle ?? "Book",
                        onCancel: {
                            showingConversionStatus = false
                            onRequestAudioRetry()
                        },
                        onRetry: {
                            showingConversionStatus = false
                            onRequestAudioRetry()
                        }
                    )
                }
        }
        .compatOnChange(of: hasAudio) { isAudioReady in
            if isAudioReady, !playerMounted { mountPlayerIfPossible() }
        }
        .compatOnChange(of: globalPlayer.firstSegmentReady) { ready in
            if ready, settings.useEmbeddedRuntime { wireEmbeddedPositionObservers() }
        }
        .compatOnChange(of: currentChapterIndex) { newIndex in
            reloadCurrentChapter(index: newIndex)
            settings.saveChapterIndex(newIndex, for: fulltext.jobId)
            // Mini player / full player read this to detect when the
            // reader has drifted off the audio position and surface
            // the "where to start" divergence dialog on the next play
            // tap. UserDefaults is the only cross-view channel that
            // works whether the reader is foreground or backgrounded.
            UserDefaults.standard.set(
                newIndex,
                forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey
            )
            // The reading-ratio + sentenceId published by ReaderView
            // refer to the previous chapter; reset both so a play tap
            // fired before the new chapter's first page-change won't
            // seek using the old chapter's offset / anchor. ReaderView
            // re-publishes on appear.
            UserDefaults.standard.set(
                0.0,
                forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey
            )
            UserDefaults.standard.removeObject(
                forKey: AudioPlayer.readerCurrentSentenceIdDefaultsKey
            )
            WidgetDataSync.updateLastRead(
                bookId: fulltext.jobId,
                chapterIndex: newIndex,
                totalChapters: fulltext.chapters.count
            )
            cacheManager.refreshCachedIndices()
            cacheManager.prefetchNext(2, from: newIndex)
        }
        .onAppear {
            let saved = settings.savedChapterIndex(for: fulltext.jobId)
            if saved > 0 {
                currentChapterIndex = saved
            } else if currentChapterIndex == 0 {
                currentChapterIndex = firstReadableChapterIndex
            }
            // Seed the reader-position channel so a play tap right
            // after launch can already detect divergence without
            // waiting for the first compatOnChange to fire.
            UserDefaults.standard.set(
                currentChapterIndex,
                forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey
            )
            reloadCurrentChapter(index: currentChapterIndex)
            if hasAudio { mountPlayerIfPossible() }
            cacheManager.refreshCachedIndices()
            cacheManager.prefetchNext(2, from: currentChapterIndex)
        }
        .onDisappear {
            positionTask?.cancel()
            sentenceTask?.cancel()
            settings.saveChapterIndex(currentChapterIndex, for: fulltext.jobId)
            WidgetDataSync.updateLastRead(
                bookId: fulltext.jobId,
                chapterIndex: currentChapterIndex,
                totalChapters: fulltext.chapters.count
            )
            if playerMounted { player.pause() }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let chapter = resolveChapter(at: currentChapterIndex) {
            ReaderView(
                chapter: chapter,
                spans: spans,
                currentSentenceId: currentSentenceId,
                onJumpToSentence: jumpToSentence,
                onAdvanceChapter: advanceToNextChapter,
                onPreviousChapter: returnToPreviousChapter,
                onCenterTap: { withAnimation(.easeInOut(duration: 0.25)) { chromeVisible.toggle() } },
                chromeVisible: chromeVisible,
                onAutoHideChrome: { autoHideChromeIfNeeded() },
                onRestoreChrome: { restoreChromeIfNeeded() },
                onLinkTap: { url in handleEpubLink(url) },
                onJumpToPlayerPosition: jumpToPlayerPosition,
                playerChapterLabel: divergencePlayerChapterLabel
            )
        } else if !fulltext.chapters.isEmpty {
            ReaderView(
                chapter: fulltext.chapters[0],
                spans: spans,
                currentSentenceId: currentSentenceId,
                onJumpToSentence: jumpToSentence,
                onAdvanceChapter: advanceToNextChapter,
                onPreviousChapter: returnToPreviousChapter,
                onCenterTap: { withAnimation(.easeInOut(duration: 0.25)) { chromeVisible.toggle() } },
                chromeVisible: chromeVisible,
                onAutoHideChrome: { autoHideChromeIfNeeded() },
                onRestoreChrome: { restoreChromeIfNeeded() },
                onLinkTap: { url in handleEpubLink(url) },
                onJumpToPlayerPosition: jumpToPlayerPosition,
                playerChapterLabel: divergencePlayerChapterLabel
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "text.book.closed")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("No content available")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Best-effort resolver for an EPUB internal link. Returns `true` if
    /// we navigated to a chapter — the UITextView delegate will then
    /// suppress its default "open externally" behaviour. Returns `false`
    /// for absolute http/https URLs so iOS opens Safari, and for any
    /// internal link we couldn't match (no chapter href map is
    /// available — `EbookFulltext.Chapter` carries only `index`/`name`,
    /// so we fall back to a fuzzy name-substring match against the
    /// link's fragment / last-path-component).
    private func handleEpubLink(_ url: URL) -> Bool {
        if let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" || scheme == "mailto" {
            return false  // iOS opens externally
        }
        // Pull the candidate name from the URL — strip extension, treat
        // anchor fragment as a fallback search term.
        let base = url.lastPathComponent
            .replacingOccurrences(of: ".xhtml", with: "")
            .replacingOccurrences(of: ".html", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let fragment = (url.fragment ?? "").lowercased()
        let needle = base.isEmpty ? fragment : base
        guard !needle.isEmpty else { return false }

        if let match = fulltext.chapters.first(where: { chapter in
            let name = (chapter.name ?? "").lowercased()
            return !name.isEmpty && (name.contains(needle) || needle.contains(name))
        }) {
            let targetIndex = max(0, match.index - 1)
            if targetIndex != currentChapterIndex {
                currentChapterIndex = targetIndex
            }
            // Bring chrome back so the user can confirm where they
            // landed — same pattern as TOC jump.
            restoreChromeIfNeeded()
            return true
        }
        return false  // give up, let iOS try
    }

    private func resolveChapter(at index: Int) -> EbookFulltext.Chapter? {
        let candidates = [
            fulltext.chapters.first(where: { $0.index == index + 1 }),
            fulltext.chapters.first(where: { $0.index == index }),
            (index >= 0 && index < fulltext.chapters.count ? fulltext.chapters[index] : nil),
        ]
        for candidate in candidates {
            if let ch = candidate, ch.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10 {
                return ch
            }
        }
        return candidates.compactMap { $0 }.first
    }

    private static let frontMatterNames: Set<String> = [
        "capa", "rosto", "créditos", "creditos", "sumário", "sumario",
        "copyright", "cover", "title page", "table of contents",
        "dedicatória", "dedicatoria", "epígrafe", "epigrafe",
    ]

    private func isLikelyFrontMatter(_ ch: EbookFulltext.Chapter, arrayIndex: Int) -> Bool {
        let name = (ch.name ?? "").lowercased()
        if Self.frontMatterNames.contains(where: { name.contains($0) }) { return true }
        let text = ch.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if arrayIndex < 10, text.count < 500, name.hasPrefix("chapter ") { return true }
        return false
    }

    private var firstReadableChapterIndex: Int {
        for (i, ch) in fulltext.chapters.enumerated() {
            let text = ch.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 10 else { continue }
            if !isLikelyFrontMatter(ch, arrayIndex: i) { return i }
        }
        if let first = fulltext.chapters.firstIndex(where: {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10
        }) {
            return first
        }
        return 0
    }

    // MARK: - Idle player bar (no audio yet)

    // MARK: - Custom top bar (replaces NavigationStack's bar)

    private var topBarTitle: String {
        if let t = snapshot?.bookTitle, !t.isEmpty { return t }
        let idx = currentChapterIndex
        if idx >= 0, idx < fulltext.chapters.count {
            return fulltext.chapters[idx].displayTitle
        }
        return "Reader"
    }

    private var customTopBar: some View {
        HStack(spacing: 16) {
            // Prefer the live job snapshot's book title (set by the
            // FastAPI SSE) — falls back to the chapter's display title
            // and finally to a generic "Reader" so the bar always has
            // something to anchor on.
            Text(topBarTitle)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                showingSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .regular))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel("Search in book")

            Button {
                showingReaderSettings = true
            } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 17, weight: .regular))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel("Reader settings")

            Button {
                showingToc = true
            } label: {
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 17, weight: .regular))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel("Table of contents")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(readerBackground.opacity(0.96))
        .overlay(alignment: .bottom) {
            Divider().background(readerForeground.opacity(0.15))
        }
    }

    private var idlePlayerBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                coverArtwork
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Book cover")
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(currentChapterTitle)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let banner = statusBanner, !banner.isEmpty {
                        let isError = banner.lowercased().contains("failed")
                            || banner.lowercased().contains("unavailable")
                        HStack(spacing: 4) {
                            if isError {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            } else {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                            Text(banner)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else if let author = fulltext.bookAuthor, !author.isEmpty {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if statusBanner != nil {
                    Button { showingConversionStatus = true } label: {
                        Image(systemName: "info.circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Conversion status")
                } else {
                    Menu {
                        Button {
                            onRequestPlay?(0, nil)
                        } label: {
                            Label("From the beginning", systemImage: "play")
                        }
                        Button {
                            onRequestPlay?(currentChapterIndex, nil)
                        } label: {
                            Label("From current chapter", systemImage: "play.rectangle")
                        }
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 36))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Play audio")
                }
            }
        }
        .compatHorizontalSafeAreaPadding(20)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { showingFullPlayer = true }
    }

    // MARK: - Player bar

    @ViewBuilder
    private var playerBar: some View {
        let ap = activePlayer
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                coverArtwork
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(currentChapterTitle)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let author = fulltext.bookAuthor, !author.isEmpty {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                transportControls(player: ap)
                // The transport row already exposes the unified "..." menu
                // (speed + sleep + secondary skips). Dropping the legacy
                // outer Menu so the bar stops rendering two ellipsis
                // buttons next to each other.
            }

            scrubber(player: ap)
        }
        .compatHorizontalSafeAreaPadding(20)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { showingFullPlayer = true }
        .accessibilityIdentifier("instantReader.playerBar")
    }

    @ViewBuilder
    private var coverArtwork: some View {
        // Pull the book cover from the library (LibraryStore writes
        // it during importBook). Falls back to a tinted glyph.
        if let cover = currentBookCover, let img = platformImage(from: cover) {
            img.resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(colors: [Color.accentColor.opacity(0.4),
                                         Color.accentColor.opacity(0.1)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                Image(systemName: "headphones")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
        }
    }

    private var currentBookCover: Data? { coverPNG }


    private func transportControls(player: AudioPlayer) -> some View {
        HStack(spacing: 24) {
            Button {
                switch player.playTapDecision(readerChapterIndex: currentChapterIndex) {
                case .pause, .resume:
                    player.togglePlayPause()
                case .offerStartChoice:
                    pendingAnchor = .capture(readerChapterIndex: currentChapterIndex)
                }
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 36))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? L10n.string("player.pause") : L10n.string("player.play"))
            .playDivergenceDialog(player: player, anchor: $pendingAnchor)

            Button {
                if currentChapterIndex + 1 < fulltext.chapters.count {
                    currentChapterIndex += 1
                }
                player.nextChapter()
            } label: {
                Image(systemName: "forward.end.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(currentChapterIndex + 1 >= fulltext.chapters.count)
            .accessibilityLabel("Next chapter")

            // "..." popover — speed + sleep + secondary skips. Same
            // contract as the other player surfaces.
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
                Button {
                    if currentChapterIndex > 0 { currentChapterIndex -= 1 }
                    player.previousChapter()
                } label: {
                    Label(L10n.string("player.previousChapter"), systemImage: "backward.end.fill")
                }
                .disabled(currentChapterIndex == 0)
                Button { player.skip(by: -15) } label: {
                    Label(L10n.string("player.skipBack15"), systemImage: "gobackward.15")
                }
                Button { player.skip(by: 30) } label: {
                    Label(L10n.string("player.skipForward15"), systemImage: "goforward.30")
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.title3)
            }
            .accessibilityLabel(L10n.string("player.more"))
        }
    }

    private func scrubber(player: AudioPlayer) -> some View {
        HStack(spacing: 8) {
            Text(format(seconds: player.positionSeconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { player.positionSeconds },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.durationSeconds, 1),
                onEditingChanged: { editing in
                    #if os(iOS)
                    let generator = UIImpactFeedbackGenerator(style: editing ? .light : .medium)
                    generator.impactOccurred()
                    #endif
                }
            )
            .accessibilityLabel("Playback position")
            Text(format(seconds: player.durationSeconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .leading)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func rateMenu(player: AudioPlayer) -> some View {
        Section("Speed") {
            ForEach(PlaybackRate.allCases) { rate in
                Button {
                    player.setRate(rate)
                } label: {
                    HStack {
                        Text(rate.label)
                        if player.rate == rate {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sleepTimerMenu(player: AudioPlayer) -> some View {
        Section("Sleep timer") {
            ForEach([0, 5, 15, 30, 45, 60], id: \.self) { mins in
                Button {
                    player.setSleepTimer(seconds: TimeInterval(mins * 60))
                } label: {
                    HStack {
                        Text(mins == 0 ? "Off" : "\(mins) min")
                        if mins == 0, player.sleepTimerRemaining <= 0 {
                            Image(systemName: "checkmark")
                        } else if mins != 0,
                                  abs(player.sleepTimerRemaining - TimeInterval(mins * 60)) < 60 {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            if player.sleepTimerRemaining > 0 {
                Text("Active: \(format(seconds: player.sleepTimerRemaining)) left")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - TOC

    @ViewBuilder
    private var tocSheet: some View {
        CompatNavigationStack {
            List {
                ForEach(fulltext.chapters.filter {
                    $0.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10
                }) { chapter in
                    Button {
                        let target = max(0, chapter.index - 1)
                        currentChapterIndex = target
                        if playerMounted {
                            player.play(snapshot: snapshot ?? JobSnapshot.empty,
                                         startingAt: target)
                        }
                        // Same Apple Books pattern as PlayerReader — jumping
                        // to a new chapter restores chrome so the user can
                        // confirm where they landed.
                        restoreChromeIfNeeded()
                        showingToc = false
                    } label: {
                        HStack {
                            Text("\(chapter.index)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                            Text(chapter.displayTitle)
                                .lineLimit(2)
                            Spacer()
                            chapterCacheIcon(for: max(0, chapter.index - 1))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Chapters")
            .compatInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showingToc = false }
                }
                ToolbarItem(placement: .compatPrimaryTrailing) {
                    Button {
                        cacheManager.downloadAll()
                    } label: {
                        Label("Download All", systemImage: "arrow.down.circle")
                    }
                    .disabled(cacheManager.cachedIndices.count == fulltext.chapters.filter {
                        $0.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10
                    }.count)
                }
            }
        }
        .compatPresentationDetents()
    }

    @ViewBuilder
    private func chapterCacheIcon(for index: Int) -> some View {
        switch cacheManager.status(for: index) {
        case .cached:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
                .accessibilityLabel("Downloaded")
        case .generating:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Generating")
        case .notStarted:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
                .accessibilityLabel("Not downloaded")
        }
    }

    // MARK: - Player wiring

    private func wireEmbeddedPositionObservers() {
        positionTask?.cancel()
        positionTask = Task { @MainActor in
            for await pos in globalPlayer.position {
                if Task.isCancelled { break }
                if globalPlayer.activeSentenceId != nil {
                    self.currentSentenceId = globalPlayer.activeSentenceId
                } else {
                    _ = sync.update(positionSeconds: pos)
                }
                if globalPlayer.currentChapterIndex != currentChapterIndex {
                    currentChapterIndex = globalPlayer.currentChapterIndex
                }
            }
        }
        sentenceTask?.cancel()
        sentenceTask = Task { @MainActor in
            for await id in sync.currentSentence {
                if Task.isCancelled { break }
                if globalPlayer.activeSentenceId == nil {
                    self.currentSentenceId = id
                }
            }
        }
    }

    private func mountPlayerIfPossible() {
        guard let snap = snapshot, !snap.playableChapters.isEmpty else { return }
        // Reuse the @StateObject `player` instance so `objectWillChange`
        // subscriptions stay valid. Reconfiguring is enough — `play()`
        // already tears down the underlying AVQueuePlayer.
        player.backendBaseURL = backendBaseURL
        player.coverArtData = coverPNG     // surface to MPNowPlayingInfoCenter
        player.play(snapshot: snap, startingAt: currentChapterIndex)
        playerMounted = true

        positionTask?.cancel()
        positionTask = Task { @MainActor in
            for await pos in player.position {
                if Task.isCancelled { break }
                _ = sync.update(positionSeconds: pos)
                if player.currentChapterIndex != currentChapterIndex {
                    currentChapterIndex = player.currentChapterIndex
                }
            }
        }
        sentenceTask?.cancel()
        sentenceTask = Task { @MainActor in
            for await id in sync.currentSentence {
                if Task.isCancelled { break }
                self.currentSentenceId = id
            }
        }
    }

    private func reloadCurrentChapter(index: Int) {
        guard index >= 0,
              let chapter = resolveChapter(at: index) else {
            spans = []
            return
        }
        currentSentenceId = nil
        let computed = chapter.splitSentences()
        spans = computed
        sync.load(chapter: chapter,
                  chapterDurationSeconds: playerMounted ? player.durationSeconds : 0)
    }

    /// Idempotent dim — every page turn fires the callback, but we only
    /// animate the chrome out when it was actually showing.
    private func autoHideChromeIfNeeded() {
        guard chromeVisible else { return }
        withAnimation(.easeInOut(duration: 0.25)) { chromeVisible = false }
    }

    /// Idempotent restore — called on TOC/search/bookmark jump and on
    /// edge-tap when chrome was hidden (Apple Books pattern).
    private func restoreChromeIfNeeded() {
        guard !chromeVisible else { return }
        withAnimation(.easeInOut(duration: 0.25)) { chromeVisible = true }
    }

    private func jumpToSentence(_ span: SentenceSpan) {
        guard let entry = sync.timing.first(where: { $0.id == span.id }) else { return }
        let seconds = TimeInterval(entry.startMs) / 1000.0
        if playerMounted { player.seek(to: seconds) }
    }

    /// Returns `true` if there *is* a next chapter and we advanced.
    /// Called from `ReaderView` when the user pages past the last page
    /// of the current chapter — without this, paginated mode dead-ends
    /// after page 1 of chapter 0 and the rest of the book is invisible.
    private func advanceToNextChapter() -> Bool {
        guard currentChapterIndex + 1 < fulltext.chapters.count else { return false }
        currentChapterIndex += 1
        return true
    }

    private func returnToPreviousChapter() -> Bool {
        guard currentChapterIndex > 0 else { return false }
        currentChapterIndex -= 1
        return true
    }

    /// Drives the "Follow audio" pill. Snaps the reader's visible
    /// chapter to whatever chapter the AudioPlayer is currently
    /// narrating. Sentence-level highlight resumes on its own once
    /// `currentSentenceId` lands on a span in the new chapter.
    private func jumpToPlayerPosition() {
        let activePlayer = embeddedAudioReady ? globalPlayer : player
        let targetIndex = activePlayer.currentChapterIndex
        guard targetIndex != currentChapterIndex,
              fulltext.chapters.indices.contains(targetIndex) else { return }
        currentChapterIndex = targetIndex
    }

    /// Surfaces the chapter the audio is narrating in the floating
    /// pill — nil when the audio matches the reader (so the pill
    /// stays generic / hidden). Used to inform users in passing
    /// without forcing them to open the TOC / full player.
    ///
    /// Visible whenever the player has a snapshot AND a chapter
    /// different from the reader's — we deliberately do NOT gate on
    /// `isPlaying` because the most common divergence is cold-launch:
    /// app opens, queue is paused at last-played chapter 5, user
    /// scrolls to chapter 0 from the library — they still want to
    /// know where the queue will resume from when they hit Play.
    private var divergencePlayerChapterLabel: String? {
        let activePlayer = embeddedAudioReady ? globalPlayer : player
        guard activePlayer.snapshot != nil else { return nil }
        let target = activePlayer.currentChapterIndex
        guard target != currentChapterIndex,
              fulltext.chapters.indices.contains(target) else { return nil }
        let title = fulltext.chapters[target].displayTitle
        return title.isEmpty ? nil : title
    }

    // MARK: - Theme colours (delegated to ReaderTheme)

    private var readerBackground: Color {
        settings.readerTheme.background(
            customBg: settings.readerTheme == .custom ? settings.readerCustomColors.background : nil
        )
    }

    private var readerForeground: Color {
        settings.readerTheme.foreground(
            customFg: settings.readerTheme == .custom ? settings.readerCustomColors.foreground : nil
        )
    }

    private var currentChapterTitle: String {
        resolveChapter(at: currentChapterIndex)?.displayTitle
            ?? fulltext.bookTitle
            ?? "—"
    }

    private func positionLabel(_ p: AudioPlayer) -> String {
        let pos = format(seconds: p.positionSeconds)
        let dur = format(seconds: p.durationSeconds)
        return "\(pos) / \(dur)"
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
}

// MARK: - Chrome hide/show (Safari-like immersive reading)

/// Hides the nav bar, status bar AND root TabView's tab bar for
/// immersive reading. Shared between `InstantReaderView` (local EPUB)
/// and `PlayerReaderView` (server-streamed) so both readers behave
/// identically when the user taps to dim chrome.
struct ChromeVisibilityModifier: ViewModifier {
    let visible: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            content
                .navigationBarHidden(true)
                .statusBarHidden(!visible)
                .toolbar(visible ? .visible : .hidden, for: .tabBar)
        } else {
            content
                .navigationBarHidden(true)
                .statusBarHidden(!visible)
        }
        #else
        content
        #endif
    }
}

private extension JobSnapshot {
    /// Empty placeholder so the TocDrawer button can call `play(snapshot:)`
    /// before audio is available. The underlying AudioPlayer no-ops when
    /// `playableChapters` is empty.
    static let empty = JobSnapshot(
        jobId: "",
        state: "pending",
        bookTitle: nil, bookAuthor: nil,
        coverUrl: nil, coverMimeType: nil,
        engine: nil, voice: nil, language: nil,
        progressPercent: nil,
        chaptersTotal: nil, chaptersCompleted: nil,
        chapterProgress: nil, outputs: nil,
        logUrl: nil, error: nil, lastActivityAt: nil
    )
}
