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
    @State private var sync = SyncEngine()
    @State private var spans: [SentenceSpan] = []
    @State private var currentSentenceId: String?
    @State private var positionTask: Task<Void, Never>?
    @State private var sentenceTask: Task<Void, Never>?
    @State private var showingToc = false
    @State private var pendingPlayAnchor: SentenceSpan?  // sentence the user tapped → "Play from here"
    @State private var showingPlayMenu = false
    @State private var showingConversionStatus = false

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
        .safeAreaInset(edge: .bottom, spacing: 0) {
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
        }
        .toolbar {
            ToolbarItem(placement: .compatPrimaryTrailing) {
                Button {
                    showingToc = true
                } label: { Image(systemName: "list.bullet.indent") }
            }
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
        }
        .onAppear {
            let saved = settings.savedChapterIndex(for: fulltext.jobId)
            if saved > 0 {
                currentChapterIndex = saved
            } else if currentChapterIndex == 0 {
                currentChapterIndex = firstReadableChapterIndex
            }
            reloadCurrentChapter(index: currentChapterIndex)
            if hasAudio { mountPlayerIfPossible() }
        }
        .onDisappear {
            positionTask?.cancel()
            sentenceTask?.cancel()
            settings.saveChapterIndex(currentChapterIndex, for: fulltext.jobId)
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
                onPreviousChapter: returnToPreviousChapter
            )
        } else if !fulltext.chapters.isEmpty {
            ReaderView(
                chapter: fulltext.chapters[0],
                spans: spans,
                currentSentenceId: currentSentenceId,
                onJumpToSentence: jumpToSentence,
                onAdvanceChapter: advanceToNextChapter,
                onPreviousChapter: returnToPreviousChapter
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

    @ViewBuilder
    private var idlePlayerBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                coverArtwork
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

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
                }
            }
        }
        .compatHorizontalSafeAreaPadding(20)
        .padding(.vertical, 4)
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

                Menu {
                    rateMenu(player: ap)
                    sleepTimerMenu(player: ap)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            scrubber(player: ap)
        }
        .compatHorizontalSafeAreaPadding(20)
        .padding(.vertical, 4)
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

    private func platformImage(from data: Data) -> Image? {
        guard let ui = UIImage(data: data) else { return nil }
        return Image(uiImage: ui)
    }

    private func transportControls(player: AudioPlayer) -> some View {
        HStack(spacing: 14) {
            Button {
                if currentChapterIndex > 0 { currentChapterIndex -= 1 }
                player.previousChapter()
            } label: {
                Image(systemName: "backward.fill").font(.body)
            }
            .buttonStyle(.plain)
            .disabled(currentChapterIndex == 0)

            Button {
                player.skip(by: -15)
            } label: {
                Image(systemName: "gobackward.15").font(.title3)
            }
            .buttonStyle(.plain)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 36))
            }
            .buttonStyle(.plain)

            Button {
                player.skip(by: 30)
            } label: {
                Image(systemName: "goforward.30").font(.title3)
            }
            .buttonStyle(.plain)

            Button {
                if currentChapterIndex + 1 < fulltext.chapters.count {
                    currentChapterIndex += 1
                }
                player.nextChapter()
            } label: {
                Image(systemName: "forward.fill").font(.body)
            }
            .buttonStyle(.plain)
            .disabled(currentChapterIndex + 1 >= fulltext.chapters.count)
        }
    }

    private func scrubber(player: AudioPlayer) -> some View {
        HStack(spacing: 8) {
            Text(format(seconds: player.positionSeconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Slider(
                value: Binding(
                    get: { player.positionSeconds },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.durationSeconds, 1)
            )
            Text(format(seconds: player.durationSeconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
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
                        let target = chapter.index - 1
                        currentChapterIndex = max(0, target)
                        if playerMounted {
                            player.play(snapshot: snapshot ?? JobSnapshot.empty,
                                         startingAt: max(0, target))
                        }
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
                            if let snapshot,
                               snapshot.playableChapters.contains(where: { $0.index == chapter.index - 1 }) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundStyle(.tint)
                            }
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
            }
        }
        .compatPresentationDetents()
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
        let computed = chapter.splitSentences()
        spans = computed
        sync.load(chapter: chapter,
                  chapterDurationSeconds: playerMounted ? player.durationSeconds : 0)
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

    // MARK: - Theme colours (mirrors ReaderView)

    /// Reader background colour derived from `settings.readerTheme`.
    /// Used to tint the status strip and player bar so they feel like
    /// continuations of the reading surface rather than system chrome.
    private var readerBackground: Color {
        switch settings.readerTheme {
        case .light:     return .platformSystemBackground
        case .sepia:     return Color(red: 0xF8/255.0, green: 0xF0/255.0, blue: 0xE0/255.0)
        case .parchment: return Color(red: 0xF4/255.0, green: 0xEC/255.0, blue: 0xD8/255.0)
        case .paper:     return Color(red: 0xE8/255.0, green: 0xE2/255.0, blue: 0xD5/255.0)
        case .dark:      return Color(red: 0x1C/255.0, green: 0x1C/255.0, blue: 0x1E/255.0)
        case .black:     return .black
        case .custom:
            let bg = settings.readerCustomColors.background
            return Color(red: bg.0, green: bg.1, blue: bg.2)
        }
    }

    /// Reader foreground colour derived from `settings.readerTheme`.
    private var readerForeground: Color {
        switch settings.readerTheme {
        case .light:     return .primary
        case .sepia:     return Color(red: 0x5B/255.0, green: 0x46/255.0, blue: 0x36/255.0)
        case .parchment: return Color(red: 0x3D/255.0, green: 0x2F/255.0, blue: 0x1F/255.0)
        case .paper:     return Color(red: 0x2A/255.0, green: 0x25/255.0, blue: 0x20/255.0)
        case .dark:      return Color(red: 0xE8/255.0, green: 0xE8/255.0, blue: 0xE8/255.0)
        case .black:     return Color(red: 0xE0/255.0, green: 0xE0/255.0, blue: 0xE0/255.0)
        case .custom:
            let fg = settings.readerCustomColors.foreground
            return Color(red: fg.0, green: fg.1, blue: fg.2)
        }
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
