import SwiftUI
#if os(iOS)
import UIKit
#endif

enum InstantReaderIndexMapper {
    static func playableIndex(forEpubIndex epubIndex: Int, in snapshot: JobSnapshot) -> Int? {
        snapshot.playableChapters.firstIndex { $0.index == epubIndex }
    }

    static func playableIndexOrClamped(forEpubIndex epubIndex: Int, in snapshot: JobSnapshot) -> Int {
        let playable = snapshot.playableChapters
        return playable.firstIndex { $0.index == epubIndex }
            ?? max(0, min(epubIndex, playable.count - 1))
    }

    static func epubIndex(forPlayableIndex playableIndex: Int, in snapshot: JobSnapshot) -> Int? {
        let playable = snapshot.playableChapters
        guard playable.indices.contains(playableIndex) else { return nil }
        return playable[playableIndex].index
    }

    /// Resolve a fulltext chapter from a zero-based EPUB index.
    ///
    /// The backend numbers fulltext chapters from 1 (`chapter.index`),
    /// while every UI cursor we hand in (`AudioPlayer.currentChapterIndex`,
    /// reader-position channels, TOC taps after translation) is zero-based.
    /// Lookup order:
    ///   1. exact match on the 1-based `chapter.index`,
    ///   2. positional fallback inside `fulltext.chapters` for the same
    ///      zero-based slot.
    ///
    /// Both paths refuse negative indices and empty fulltexts so callers
    /// can pass an unchecked `Int` (e.g. the `?? -1` fallback used in
    /// PlayerReaderView's bookmark sheet) without risking a crash when
    /// the snapshot shrinks or fulltext hasn't been hydrated yet.
    static func chapter(
        in fulltext: EbookFulltext,
        atZeroBasedIndex zeroBasedIndex: Int
    ) -> EbookFulltext.Chapter? {
        guard zeroBasedIndex >= 0, !fulltext.chapters.isEmpty else { return nil }
        let target = zeroBasedIndex + 1
        if let exact = fulltext.chapters.first(where: { $0.index == target }) {
            return exact
        }
        return zeroBasedIndex < fulltext.chapters.count
            ? fulltext.chapters[zeroBasedIndex]
            : nil
    }
}

enum InstantReaderChromeMetrics {
    /// Apple Books-style chrome overlays the page instead of reserving
    /// full bar height. Keep only a tiny breathing room so hidden chrome
    /// leaves the page visually close to the top edge.
    static let topBarHeight: CGFloat = 8
    /// Apple Books-style bottom controls also overlay the page. A small
    /// fixed inset avoids the home indicator/page footer feeling glued
    /// to the text without creating a large empty band.
    static let bottomBarHeight: CGFloat = 8

    /// `InstantReaderView` stays inside SwiftUI's normal safe-area
    /// container so the system keeps the status bar, home indicator and
    /// tab bar honest. These metrics reserve only our custom chrome;
    /// adding the live safe-area again double-counts it and pushes the
    /// bars/text too far inward on device.
    static func contentTopInset(safeAreaTop: CGFloat) -> CGFloat {
        _ = safeAreaTop
        return topBarHeight
    }

    static func contentBottomInset(safeAreaBottom: CGFloat) -> CGFloat {
        _ = safeAreaBottom
        return bottomBarHeight
    }
}

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
    var onClose: (() -> Void)? = nil
    @ObservedObject var cacheManager: ChapterCacheManager

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var globalPlayer: AudioPlayer
    @EnvironmentObject private var playerPresentation: PlayerPresentation
    @EnvironmentObject private var readerCoordinator: ReaderCoordinator
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
    /// Identity of the `AudioPlayer` instance the position / sentence
    /// loops are currently subscribed to. Prevents the embedded and
    /// snapshot paths from each spawning a parallel subscription when
    /// they happen to fire in the same runloop tick — see
    /// `installPositionLoop(on:isEmbedded:)`.
    @State private var activeSubscriptionPlayer: ObjectIdentifier?
    @State private var showingToc = false
    @State private var showingSearch = false
    @State private var pendingPlayAnchor: SentenceSpan?  // sentence the user tapped → "Play from here"
    @State private var showingPlayMenu = false
    @State private var showingConversionStatus = false
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

    // MARK: - Chrome layout
    //
    // The reader content must stay inside the safe reading corridor:
    // device top safe area + custom top bar at the top, and home
    // indicator + bottom audio/status chrome at the bottom. We still use
    // a ZStack so chrome can fade/slide independently, but the text is
    // never allowed underneath the bars when they appear.

    var body: some View {
        GeometryReader { proxy in
            let topInset = InstantReaderChromeMetrics.contentTopInset(
                safeAreaTop: proxy.safeAreaInsets.top
            )
            let bottomInset = InstantReaderChromeMetrics.contentBottomInset(
                safeAreaBottom: proxy.safeAreaInsets.bottom
            )

            ZStack(alignment: .center) {
                content(topInset: topInset, bottomInset: bottomInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 0) {
                    if chromeVisible {
                        customTopBar
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                    if chromeVisible {
                        VStack(spacing: 0) {
                            Divider()
                                .background(readerForeground.opacity(0.15))
                            if showTransport {
                                playerBar
                                    .padding(.vertical, 8)
                            } else {
                                idlePlayerBar
                                    .padding(.vertical, 8)
                            }
                        }
                        .background(readerBackground.opacity(0.96))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Test-only: surfaces flicker-event counters to UI tests.
                // No-op (renders nothing) unless `-uiTestFlickerProbe` armed.
                FlickerProbeOverlay()
            }
        }
        .modifier(ChromeVisibilityModifier(visible: chromeVisible))
        .readerChromeVisible(chromeVisible)
        .sheet(isPresented: $showingReaderSettings) {
            ReaderSettingsSheet()
                .environmentObject(settings)
        }
        .sheet(isPresented: $showingSearch) {
            ReaderSearchOverlay(
                chapters: fulltext.chapters,
                onJumpToChapter: { idx in
                    // ReaderSearchOverlay emits FulltextChapter.index
                    // (1-based on the wire). `currentChapterIndex` is
                    // 0-based EPUB axis — the same axis the player
                    // mapper, ReaderCoordinator, WidgetDataSync, and
                    // cacheManager all expect. Skipping `- 1` here
                    // drifted every downstream cursor by one chapter
                    // after a search jump.
                    currentChapterIndex = max(0, idx - 1)
                },
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
            if ready, settings.useEmbeddedRuntime {
                wireEmbeddedPositionObservers()
            } else if !ready, playerMounted {
                // Embedded player lost its segments (e.g. segment reset on
                // network error) — fall back to the local mounted player so
                // the position loop doesn't track a stale globalPlayer.
                installPositionLoop(on: player, isEmbedded: false)
            }
        }
        .compatOnChange(of: currentChapterIndex) { newIndex in
            FlickerProbe.shared.chapterInfo = "\(newIndex)/\(fulltext.chapters.count)"
            reloadCurrentChapter(index: newIndex)
            settings.saveChapterIndex(newIndex, for: fulltext.jobId)
            // ReaderCoordinator is the source of truth — this single
            // call (a) updates every play surface that derives
            // `readerChapterIndex` from it, (b) resets the
            // page-cursor (ratio + sentenceId) so a play tap fired
            // before the new chapter's first ReaderView re-render
            // doesn't seek with stale data, and (c) debounces a
            // single mirror write to the App Group container for
            // widget visibility.
            readerCoordinator.setChapter(newIndex)
            WidgetDataSync.updateLastRead(
                bookId: fulltext.jobId,
                chapterIndex: newIndex,
                totalChapters: fulltext.chapters.count
            )
            cacheManager.refreshCachedIndices()
            cacheManager.prefetchNext(2, from: newIndex)
        }
        .onAppear {
            // UI tests can force a clean opening position (first readable
            // chapter) so chapter-crossing automation isn't blocked by a
            // previously-saved position deep in the book.
            let forceReset = ProcessInfo.processInfo.arguments.contains("-uiTestResetReaderPosition")
            let saved = forceReset ? 0 : settings.savedChapterIndex(for: fulltext.jobId)
            if saved > 0 {
                currentChapterIndex = saved
            } else if currentChapterIndex == 0 {
                currentChapterIndex = firstReadableChapterIndex
            }
            // Seed the coordinator so a play tap right after launch
            // already knows where the reader is, without waiting
            // for the first compatOnChange to fire.
            readerCoordinator.setChapter(currentChapterIndex)
            FlickerProbe.shared.chapterInfo = "\(currentChapterIndex)/\(fulltext.chapters.count)"
            reloadCurrentChapter(index: currentChapterIndex)
            if hasAudio { mountPlayerIfPossible() }
            cacheManager.refreshCachedIndices()
            cacheManager.prefetchNext(2, from: currentChapterIndex)
        }
        .onDisappear {
            positionTask?.cancel()
            sentenceTask?.cancel()
            activeSubscriptionPlayer = nil
            settings.saveChapterIndex(currentChapterIndex, for: fulltext.jobId)
            WidgetDataSync.updateLastRead(
                bookId: fulltext.jobId,
                chapterIndex: currentChapterIndex,
                totalChapters: fulltext.chapters.count
            )
            // Flush the debounced widget write immediately so the
            // home-screen "Continue Reading" tile reflects the final
            // chapter the moment the user leaves the book. Same for
            // the reader-position UserDefaults mirror.
            WidgetDataSync.flushLastRead()
            readerCoordinator.flush()
            if playerMounted { player.pause() }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(topInset: CGFloat, bottomInset: CGFloat) -> some View {
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
                playerChapterLabel: divergencePlayerChapterLabel,
                chromeTopInset: chromeVisible ? topInset : 0,
                chromeBottomInset: chromeVisible ? bottomInset : 0,
                useStableBodyHeight: true,
                bookChapters: fulltext.chapters,
                onScrolledToChapter: { mirrorScrolledChapter($0) }
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
                playerChapterLabel: divergencePlayerChapterLabel,
                chromeTopInset: chromeVisible ? topInset : 0,
                chromeBottomInset: chromeVisible ? bottomInset : 0,
                useStableBodyHeight: true,
                bookChapters: fulltext.chapters,
                onScrolledToChapter: { mirrorScrolledChapter($0) }
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "text.book.closed")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text(localized: "bookOpen.noContent")
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

    /// Engage `AudioPlayer.playOrFallback` for the chapter the user
    /// asked to start. Sibling to the existing `onRequestPlay` callback
    /// (which kicks off the server-side conversion bootstrap) — running
    /// both in the same tap gives the user immediate accessibility-speech
    /// audio while the MP3 conversion catches up in the background.
    /// `play(snapshot:)` already stops the fallback on MP3 takeover, so
    /// no extra teardown is required when the chapter audio lands.
    ///
    /// No-ops when the requested chapter has no usable text — the menu
    /// then merely fires `onRequestPlay`, mirroring the pre-slice-4
    /// behaviour exactly.
    private func startPlayOrFallback(forChapterIndex epubIndex: Int) {
        guard let chapter = resolveChapter(at: epubIndex) else { return }
        activePlayer.playOrFallback(
            snapshot: snapshot,
            chapterIndex: epubIndex,
            chapterText: chapter.text,
            languageCode: snapshot?.language
        )
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

    private var customTopBar: some View {
        HStack(spacing: 16) {
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .regular))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityLabel(L10n.string("player.close"))
            }

            Spacer(minLength: 0)

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
            .accessibilityLabel(L10n.string("instantReader.searchInBook"))

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
            .accessibilityLabel(L10n.string("instantReader.readerSettings"))

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
            .accessibilityLabel(L10n.string("instantReader.tableOfContents"))
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
                    .accessibilityLabel(L10n.string("instantReader.bookCover"))
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
                    .accessibilityLabel(L10n.string("instantReader.conversionStatus"))
                } else {
                    Menu {
                        Button {
                            startPlayOrFallback(forChapterIndex: 0)
                            onRequestPlay?(0, nil)
                        } label: {
                            Label(L10n.string("player.divergence.fromBeginning"), systemImage: "play")
                        }
                        Button {
                            startPlayOrFallback(forChapterIndex: currentChapterIndex)
                            onRequestPlay?(currentChapterIndex, nil)
                        } label: {
                            Label(L10n.string("instantReader.fromCurrentChapter"), systemImage: "play.rectangle")
                        }
                    } label: {
                        Image(systemName: activePlayer.isUsingSpeechFallback && activePlayer.isPlaying
                              ? "pause.circle.fill"
                              : "play.circle.fill")
                            .font(.system(size: 36))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel(L10n.string("instantReader.playAudio"))
                }
            }
        }
        .compatHorizontalSafeAreaPadding(20)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { playerPresentation.showFullPlayer() }
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
        .onTapGesture { playerPresentation.showFullPlayer() }
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
                    pendingAnchor = .capture(from: readerCoordinator)
                }
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 36))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? L10n.string("player.pause") : L10n.string("player.play"))
            .playDivergenceDialog(player: player, anchor: $pendingAnchor)

            Button {
                player.nextChapter()
                // Derive the new reader position from the player's current
                // chapter so the two axes stay in sync. In embedded mode
                // globalPlayer.currentChapterIndex IS the EPUB index directly
                // (enqueueSegment sets it); in local mode translate via mapper.
                if embeddedAudioReady {
                    currentChapterIndex = globalPlayer.currentChapterIndex
                } else if let epubIdx = playerEpubChapterIndex(for: player) {
                    currentChapterIndex = epubIdx
                } else if currentChapterIndex + 1 < fulltext.chapters.count {
                    currentChapterIndex += 1
                }
            } label: {
                Image(systemName: "forward.end.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(currentChapterIndex + 1 >= fulltext.chapters.count)
            .accessibilityLabel(L10n.string("instantReader.nextChapter"))

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
                    player.previousChapter()
                    // Mirror the next-chapter logic: embedded uses EPUB index
                    // directly; local uses the mapper with ±1 fallback.
                    if embeddedAudioReady {
                        currentChapterIndex = globalPlayer.currentChapterIndex
                    } else if let epubIdx = playerEpubChapterIndex(for: player) {
                        currentChapterIndex = epubIdx
                    } else if currentChapterIndex > 0 {
                        currentChapterIndex -= 1
                    }
                } label: {
                    Label(L10n.string("player.previousChapter"), systemImage: "backward.end.fill")
                }
                .disabled(currentChapterIndex == 0)
                Button { player.skip(by: -15) } label: {
                    Label(L10n.string("player.skipBack15"), systemImage: "gobackward.15")
                }
                Button { player.skip(by: 30) } label: {
                    Label(L10n.string("player.skipForward30"), systemImage: "goforward.30")
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
            .accessibilityLabel(L10n.string("instantReader.playbackPosition"))
            Text(format(seconds: player.durationSeconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .leading)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func rateMenu(player: AudioPlayer) -> some View {
        Section(L10n.string("player.speed")) {
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
        Section(L10n.string("player.sleepTimer")) {
            ForEach([0, 5, 15, 30, 45, 60], id: \.self) { mins in
                Button {
                    player.setSleepTimer(seconds: TimeInterval(mins * 60))
                } label: {
                    HStack {
                        Text(mins == 0
                                ? L10n.string("player.sleepTimerOption.off")
                                : L10n.string("instantReader.sleepMinutes", mins))
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
                Text(L10n.string("instantReader.sleepActive", format(seconds: player.sleepTimerRemaining)))
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
                            let snap = snapshot ?? JobSnapshot.empty
                            let playableTarget = InstantReaderIndexMapper
                                .playableIndex(forEpubIndex: target, in: snap) ?? 0
                            player.play(snapshot: snap, startingAt: playableTarget)
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
            .navigationTitle(L10n.string("player.chapters"))
            .compatInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("player.close")) { showingToc = false }
                }
                ToolbarItem(placement: .compatPrimaryTrailing) {
                    Button {
                        cacheManager.downloadAll()
                    } label: {
                        Label(L10n.string("player.downloadAll"), systemImage: "arrow.down.circle")
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
                .accessibilityLabel(L10n.string("instantReader.downloaded"))
        case .generating:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel(L10n.string("instantReader.generating"))
        case .notStarted:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
                .accessibilityLabel(L10n.string("instantReader.notDownloaded"))
        }
    }

    // MARK: - Player wiring

    private func wireEmbeddedPositionObservers() {
        installPositionLoop(on: globalPlayer, isEmbedded: true)
    }

    private func mountPlayerIfPossible() {
        guard let snap = snapshot, !snap.playableChapters.isEmpty else { return }
        // Reuse the @StateObject `player` instance so `objectWillChange`
        // subscriptions stay valid. Reconfiguring is enough — `play()`
        // already tears down the underlying AVQueuePlayer.
        player.backendBaseURL = backendBaseURL
        player.coverArtData = coverPNG     // surface to MPNowPlayingInfoCenter
        let playableIndex = InstantReaderIndexMapper
            .playableIndex(forEpubIndex: currentChapterIndex, in: snap) ?? 0
        player.play(snapshot: snap, startingAt: playableIndex)
        playerMounted = true
        installPositionLoop(on: player, isEmbedded: false)
    }

    /// Wire the position/sentence subscriptions to ONE AudioPlayer
    /// instance — either the global embedded one or the local mounted
    /// one. Previously these were wired from two separate functions
    /// (`wireEmbeddedPositionObservers` and `mountPlayerIfPossible`),
    /// and when both fired in the same runloop tick SwiftUI's
    /// state-batching could leave one stream's `for await` loop alive
    /// while the other claimed `positionTask`. Consolidating to a
    /// single installer with an identity guard (`activeSubscriptionPlayer`)
    /// keeps exactly ONE subscription live at any time.
    private func installPositionLoop(on activePlayer: AudioPlayer, isEmbedded: Bool) {
        let identity = ObjectIdentifier(activePlayer)
        if activeSubscriptionPlayer == identity { return }
        activeSubscriptionPlayer = identity

        positionTask?.cancel()
        positionTask = Task { @MainActor [weak activePlayer] in
            guard let activePlayer else { return }
            for await pos in activePlayer.position {
                if Task.isCancelled { break }
                if isEmbedded, activePlayer.activeSentenceId != nil {
                    self.currentSentenceId = activePlayer.activeSentenceId
                } else {
                    _ = sync.update(positionSeconds: pos)
                }
                // Only follow the player's chapter when it is actively
                // playing — an idle player sitting at chapter 0 must
                // not force the reader back to the index/TOC chapter.
                if activePlayer.isPlaying,
                   let epubIndex = playerEpubChapterIndex(for: activePlayer),
                   epubIndex != currentChapterIndex {
                    currentChapterIndex = epubIndex
                }
            }
        }

        sentenceTask?.cancel()
        sentenceTask = Task { @MainActor [weak activePlayer] in
            for await id in sync.currentSentence {
                if Task.isCancelled { break }
                // Embedded path defers to `activePlayer.activeSentenceId`
                // (per-segment SSE) when present; otherwise the
                // sync-engine's WPM-estimated cursor wins.
                if isEmbedded {
                    if activePlayer?.activeSentenceId == nil {
                        self.currentSentenceId = id
                    }
                } else {
                    self.currentSentenceId = id
                }
            }
        }
    }

    private func reloadCurrentChapter(index: Int) {
        // Resolve the index-space the timing map must key into so both the
        // wipe and the inject land in the SAME space `startFromReaderPage`
        // uses when looking up `sentenceTimingByChapter`.
        //
        // Two regimes — never conflate them:
        //  - Embedded runtime (`embeddedAudioReady`): `playableChapters` is
        //    permanently empty (segments arrive via `enqueueSegment`, no
        //    `downloadUrl`), so the playable mapper always returns nil. The
        //    embedded player's `currentChapterIndex` IS the EPUB-zero-based
        //    index (see AudioPlayer.enqueueSegment), and `startFromReaderPage`
        //    keys lookups by that same EPUB index — so key by `index`.
        //  - Local mounted player: key by the real playable-list index. When
        //    the mapper returns nil (reader on a chapter with no playable
        //    counterpart) skip the inject rather than clobber an unrelated
        //    chapter's entry with `activePlayer.currentChapterIndex`.
        let snap = snapshot ?? JobSnapshot.empty
        let playableIdx: Int? = embeddedAudioReady
            ? index
            : InstantReaderIndexMapper.playableIndex(forEpubIndex: index, in: snap)
        guard index >= 0,
              let chapter = resolveChapter(at: index) else {
            spans = []
            // Wipe stale per-sentence timing so divergence-dialog seek
            // can't land on a phantom offset from the previous chapter.
            if let playableIdx {
                activePlayer.setSentenceTiming([:], forChapterIndex: playableIdx)
            }
            return
        }
        currentSentenceId = nil
        let computed = chapter.splitSentences()
        spans = computed
        sync.load(chapter: chapter,
                  chapterDurationSeconds: showTransport ? activePlayer.durationSeconds : 0)
        // Inject sentence-id → start-ms map; skip when there is no resolvable
        // key (local player, unplayable chapter) to avoid poisoning an unrelated
        // chapter's timing entry.
        guard let playableIdx else { return }
        let map: [String: Int] = sync.timing.reduce(into: [:]) { acc, entry in
            acc[entry.id] = entry.startMs
        }
        activePlayer.setSentenceTiming(map, forChapterIndex: playableIdx)
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

    /// Continuous-scroll mode: a chapter cell scrolled into view. Mirror it
    /// into `currentChapterIndex` (only when it actually changes) so the
    /// TOC highlight, saved position, and widget last-read all track the
    /// scroll. The `onChange(of: currentChapterIndex)` handler does the
    /// heavy lifting (coordinator + persistence); guarding on inequality
    /// prevents a feedback loop with the cell's `onAppear`.
    private func mirrorScrolledChapter(_ zeroBasedIndex: Int) {
        guard zeroBasedIndex != currentChapterIndex,
              zeroBasedIndex >= 0,
              zeroBasedIndex < fulltext.chapters.count else { return }
        currentChapterIndex = zeroBasedIndex
    }

    /// Drives the "Follow audio" pill. Snaps the reader's visible
    /// chapter to whatever chapter the AudioPlayer is currently
    /// narrating. Sentence-level highlight resumes on its own once
    /// `currentSentenceId` lands on a span in the new chapter.
    ///
    /// `player.currentChapterIndex` is in the playable-chapters space;
    /// translate to the EPUB-zero-based space the reader's
    /// `currentChapterIndex` lives in before assigning.
    private func jumpToPlayerPosition() {
        let activePlayer = embeddedAudioReady ? globalPlayer : player
        guard let epubIndex = playerEpubChapterIndex(for: activePlayer),
              epubIndex != currentChapterIndex,
              fulltext.chapters.indices.contains(epubIndex) else { return }
        currentChapterIndex = epubIndex
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
        guard activePlayer.snapshot != nil,
              let epubIndex = playerEpubChapterIndex(for: activePlayer),
              epubIndex != currentChapterIndex,
              fulltext.chapters.indices.contains(epubIndex) else { return nil }
        let title = fulltext.chapters[epubIndex].displayTitle
        return title.isEmpty ? nil : title
    }

    /// Translate the player's playable-list index to the EPUB
    /// zero-based index that the reader (and `fulltext.chapters`) use.
    /// Returns `nil` when the snapshot is empty or the player is out
    /// of bounds — both of which collapse the pill back to "no
    /// divergence to surface".
    private func playerEpubChapterIndex(for player: AudioPlayer) -> Int? {
        guard let snapshot = player.snapshot else { return nil }
        return InstantReaderIndexMapper
            .epubIndex(forPlayableIndex: player.currentChapterIndex, in: snapshot)
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

/// Hides the navigation bar and, on iOS, keeps the root tab bar in sync
/// with the reader's immersive chrome. When the reader's own top/bottom
/// bars are hidden, leaving TabView's bar visible creates a lone bottom
/// strip; hide it as part of the same chrome state.
struct ChromeVisibilityModifier: ViewModifier {
    let visible: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 16, *) {
            content
                .toolbar(.hidden, for: .navigationBar)
                .statusBarHidden(false)
                .toolbar(.hidden, for: .tabBar)
        } else {
            content
                .navigationBarHidden(true)
                .statusBarHidden(false)
                .background(TabBarVisibilityController(visible: false))
        }
        #else
        content
        #endif
    }
}

#if os(iOS)
private struct TabBarVisibilityController: UIViewControllerRepresentable {
    let visible: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ viewController: UIViewController, context: Context) {
        DispatchQueue.main.async {
            viewController.tabBarController?.tabBar.isHidden = !visible
        }
    }

    static func dismantleUIViewController(_ viewController: UIViewController, coordinator: ()) {
        viewController.tabBarController?.tabBar.isHidden = false
    }
}
#endif

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
