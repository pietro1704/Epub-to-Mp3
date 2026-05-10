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

    @Environment(AppSettings.self) private var settings
    @Environment(\.horizontalSizeClass) private var hSize

    @State private var currentChapterIndex: Int = 0
    @State private var player: AudioPlayer?
    @State private var sync = SyncEngine()
    @State private var spans: [SentenceSpan] = []
    @State private var currentSentenceId: String?
    @State private var positionTask: Task<Void, Never>?
    @State private var sentenceTask: Task<Void, Never>?
    @State private var showingToc = false

    var body: some View {
        VStack(spacing: 0) {
            if let banner = statusBanner {
                statusStrip(banner)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if hasAudio {
                Divider()
                playerBar
                    .padding(.vertical, 8)
                    .background(.thinMaterial)
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
        .onChange(of: hasAudio) { _, isAudioReady in
            if isAudioReady, player == nil { mountPlayerIfPossible() }
        }
        .onChange(of: currentChapterIndex) { _, newIndex in
            reloadCurrentChapter(index: newIndex)
        }
        .onAppear {
            reloadCurrentChapter(index: currentChapterIndex)
            if hasAudio { mountPlayerIfPossible() }
        }
        .onDisappear {
            positionTask?.cancel()
            sentenceTask?.cancel()
            player?.pause()
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
                onJumpToSentence: jumpToSentence
            )
        } else {
            Text("No chapter at index \(currentChapterIndex).")
                .foregroundStyle(.secondary)
        }
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
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.thickMaterial)
    }

    // MARK: - Player bar

    @ViewBuilder
    private var playerBar: some View {
        if let player {
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
            .padding(.horizontal, 20)
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
        NavigationStack {
            List {
                ForEach(fulltext.chapters) { chapter in
                    Button {
                        let target = chapter.index - 1
                        currentChapterIndex = max(0, target)
                        if let player {
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
        .presentationDetents([.medium, .large])
    }

    // MARK: - Player wiring

    private func mountPlayerIfPossible() {
        guard let snap = snapshot, !snap.playableChapters.isEmpty else { return }
        let p = AudioPlayer(backendBaseURL: backendBaseURL)
        p.coverArtData = coverPNG     // surface to MPNowPlayingInfoCenter
        p.play(snapshot: snap, startingAt: currentChapterIndex)
        self.player = p

        positionTask?.cancel()
        positionTask = Task { @MainActor in
            for await pos in p.position {
                if Task.isCancelled { break }
                _ = sync.update(positionSeconds: pos)
                if p.currentChapterIndex != currentChapterIndex {
                    currentChapterIndex = p.currentChapterIndex
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
                  chapterDurationSeconds: player?.durationSeconds ?? 0)
    }

    private func jumpToSentence(_ span: SentenceSpan) {
        guard let entry = sync.timing.first(where: { $0.id == span.id }) else { return }
        let seconds = TimeInterval(entry.startMs) / 1000.0
        player?.seek(to: seconds)
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
