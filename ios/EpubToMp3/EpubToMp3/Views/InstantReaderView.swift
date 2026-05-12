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

    var body: some View {
        // The reader content + (optional) status strip live in the
        // base VStack. The audio player bar and the floating play FAB
        // are docked via `.safeAreaInset(edge: .bottom)` so that, in
        // portrait, they sit comfortably above the home indicator
        // without us hardcoding its 34pt height (which varies by
        // device generation — iPhone 13 mini is 21pt, the 16 Pro Max
        // is 34pt). The inset also composes with the parent navigation
        // stack so the reader's scrollable area can scroll its content
        // *behind* a translucent player bar, the HIG audiobook pattern.
        VStack(spacing: 0) {
            // Only surface the status strip when we're actively
            // bootstrapping audio. An empty/idle reader shows
            // pure text — no infinite "Generating audio…".
            if let banner = statusBanner, !banner.isEmpty {
                statusStrip(banner)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Dock the player bar at the bottom safe area. SwiftUI adds
        // the system home-indicator inset for us automatically — no
        // hardcoded 34pt — and the divider+material drift up so the
        // last line of body text never gets clipped behind the
        // player.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if hasAudio {
                VStack(spacing: 0) {
                    Divider()
                    playerBar
                        .padding(.vertical, 8)
                }
                .background(.thinMaterial)
            }
        }
        // Floating play button overlay. Using `.overlay` instead of
        // the prior `ZStack(alignment: .bottomTrailing)` keeps the FAB
        // inside the host's safe area in portrait — the prior
        // `padding(.bottom, 32)` was a fixed guess that fell **inside**
        // the home indicator on iPhone Pro Max devices.
        .overlay(alignment: .bottomTrailing) {
            if !hasAudio {
                floatingPlayButton
                    .padding(.trailing, 24)
                    .padding(.bottom, 16)
            }
        }
        .toolbar {
            ToolbarItem(placement: .compatPrimaryTrailing) {
                Button {
                    showingToc = true
                } label: { Image(systemName: "list.bullet.indent") }
            }
        }
        .sheet(isPresented: $showingToc) {
            tocSheet
        }
        .compatOnChange(of: hasAudio) { isAudioReady in
            if isAudioReady, !playerMounted { mountPlayerIfPossible() }
        }
        .compatOnChange(of: currentChapterIndex) { newIndex in
            reloadCurrentChapter(index: newIndex)
        }
        .onAppear {
            reloadCurrentChapter(index: currentChapterIndex)
            if hasAudio { mountPlayerIfPossible() }
        }
        .onDisappear {
            positionTask?.cancel()
            sentenceTask?.cancel()
            if playerMounted { player.pause() }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let chapter = fulltext.chapters.first(where: { $0.index == currentChapterIndex + 1 })
            ?? (currentChapterIndex < fulltext.chapters.count
                ? fulltext.chapters[currentChapterIndex] : nil) {
            ReaderView(
                chapter: chapter,
                spans: spans,
                currentSentenceId: currentSentenceId,
                onJumpToSentence: jumpToSentence,
                onAdvanceChapter: advanceToNextChapter,
                onPreviousChapter: returnToPreviousChapter
            )
        } else {
            Text("No chapter at index \(currentChapterIndex).")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Floating play button (audio opt-in)

    /// FAB rendered above the reader text (bottom-trailing). Tapping
    /// shows a menu with three start points: beginning of book,
    /// current chapter, or the sentence the user last tapped.
    /// Hidden once `hasAudio` is true — the bottom player bar
    /// supersedes it.
    @ViewBuilder
    private var floatingPlayButton: some View {
        Menu {
            Button {
                onRequestPlay?(0, nil)
            } label: {
                Label("From the beginning", systemImage: "play")
            }
            Button {
                onRequestPlay?(currentChapterIndex, nil)
            } label: {
                Label("From current chapter",
                      systemImage: "play.rectangle")
            }
            if let anchor = pendingPlayAnchor {
                Button {
                    onRequestPlay?(currentChapterIndex, anchor.id)
                } label: {
                    Label("From this sentence",
                          systemImage: "text.insert")
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 56, height: 56)
                    .shadow(color: .black.opacity(0.25),
                            radius: 6, x: 0, y: 3)
                Image(systemName: statusBanner == nil
                                    ? "play.fill"
                                    : "hourglass")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("Play audio")
    }

    // MARK: - Status strip

    private func statusStrip(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            if text.lowercased().contains("failed") || text.lowercased().contains("unavailable") {
                Button("Retry", action: onRequestAudioRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        // 16pt on top of the safe-area inset so the spinner / status
        // copy / Retry button never sit under the notch in landscape.
        .compatHorizontalSafeAreaPadding(16)
        .padding(.vertical, 6)
        .background(.thickMaterial)
    }

    // MARK: - Player bar

    @ViewBuilder
    private var playerBar: some View {
        if playerMounted {
            VStack(spacing: 8) {
                // Top row: artwork + title/author + transport
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

                    transportControls(player: player)

                    Menu {
                        rateMenu(player: player)
                        sleepTimerMenu(player: player)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                scrubber(player: player)
            }
            // 20pt internal margin on top of safe-area lateral inset
            // — keeps artwork, transport buttons, and scrubber thumbs
            // clear of the notch / Dynamic Island in landscape.
            .compatHorizontalSafeAreaPadding(20)
            .padding(.vertical, 4)
        }
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
        #if canImport(UIKit)
        if let ui = UIImage(data: data) { return Image(uiImage: ui) }
        #endif
        #if canImport(AppKit)
        if let ns = NSImage(data: data) { return Image(nsImage: ns) }
        #endif
        return nil
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
                ForEach(fulltext.chapters) { chapter in
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
              let chapter = fulltext.chapters.first(where: { $0.index == index + 1 })
                ?? (index < fulltext.chapters.count ? fulltext.chapters[index] : nil) else {
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

    private var currentChapterTitle: String {
        if let chapter = fulltext.chapters.first(where: { $0.index == currentChapterIndex + 1 })
            ?? (currentChapterIndex < fulltext.chapters.count
                ? fulltext.chapters[currentChapterIndex] : nil) {
            return chapter.displayTitle
        }
        return "—"
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
