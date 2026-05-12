import SwiftUI
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

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.dismiss) private var dismiss

    @StateObject private var player = AudioPlayer()
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

    var body: some View {
        CompatNavigationStack {
            Group {
                if hSize == .regular {
                    HStack(spacing: 0) {
                        readerPane
                        Divider()
                        transportPane
                            .frame(maxWidth: 360)
                    }
                } else {
                    VStack(spacing: 0) {
                        readerPane
                        Divider()
                        transportPane
                            .frame(maxHeight: 240)
                    }
                }
            }
            .navigationTitle(snapshot.bookTitle ?? "Audiobook")
            .compatInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { player.pause(); dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        #if os(iOS)
                        AirPlayPickerView()
                            .frame(width: 32, height: 32)
                        #endif
                        sleepTimerMenu
                        Button { showingToc = true } label: {
                            Image(systemName: "list.bullet.indent")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingToc) {
                TocDrawer(
                    fulltext: fulltext,
                    snapshot: snapshot,
                    currentChapterIndex: player.currentChapterIndex,
                    onJump: jumpTo(chapterIndex:)
                )
                .compatPresentationDetents()
            }
        }
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
        } else if let fulltext, let chapter = chapter(in: fulltext, at: player.currentChapterIndex) {
            ReaderView(
                chapter: chapter,
                spans: spans,
                currentSentenceId: currentSentenceId,
                onJumpToSentence: jumpToSentence
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
            HStack {
                rateButton
                Spacer()
                sleepTimerBadge
            }
        }
        .padding(20)
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { player.positionSeconds },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.durationSeconds, 1)
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
        HStack(spacing: 20) {
            Button { player.previousChapter() } label: {
                Image(systemName: "backward.fill").font(.title2)
            }
            Button { player.skipBackward(seconds: 15) } label: {
                Image(systemName: "gobackward.15").font(.title)
            }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 56))
            }
            Button { player.skipForward(seconds: 15) } label: {
                Image(systemName: "goforward.15").font(.title)
            }
            Button { player.nextChapter() } label: {
                Image(systemName: "forward.fill").font(.title2)
            }
        }
        .tint(.primary)
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

    /// Sleep timer menu for the toolbar.
    private var sleepTimerMenu: some View {
        Menu {
            Button {
                player.cancelSleepTimer()
            } label: {
                Label("Off", systemImage: "moon.slash")
            }
            Button { player.startSleepTimer(minutes: 5) } label: {
                Label("5 minutes", systemImage: "moon")
            }
            Button { player.startSleepTimer(minutes: 15) } label: {
                Label("15 minutes", systemImage: "moon")
            }
            Button { player.startSleepTimer(minutes: 30) } label: {
                Label("30 minutes", systemImage: "moon")
            }
            Button { player.startSleepTimer(minutes: 60) } label: {
                Label("1 hour", systemImage: "moon.fill")
            }
            // "End of chapter": deferred to v2 — requires knowing the
            // remaining chapter duration at schedule time, which is only
            // reliable after AVPlayerItem.duration loads asynchronously.
        } label: {
            Image(systemName: player.sleepTimerRemaining > 0 ? "moon.zzz.fill" : "moon.zzz")
                .symbolRenderingMode(.monochrome)
        }
    }

    // MARK: Bootstrap

    private func bootstrap() {
        if player.snapshot?.jobId != snapshot.jobId {
            // Reuse the @StateObject `player` instance — assigning to it
            // is not allowed under Combine ownership. Reconfigure
            // backendBaseURL on the existing object then call play().
            player.backendBaseURL = backendBaseURL
            player.play(snapshot: snapshot, startingAt: 0)
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
        streamTask?.cancel(); streamTask = nil
    }

    /// Live-stream the backend's per-chapter progress and feed each
    /// new snapshot back to the AudioPlayer so newly-finished chapters
    /// get appended to the queue. This is what gives the user
    /// chapter-by-chapter streaming playback while the rest of the
    /// audiobook is still being synthesised.
    private func subscribeToJobStream() {
        guard let baseURL = backendBaseURL else { return }
        streamTask?.cancel()
        let client = APIClient(baseURL: baseURL)
        let jobId = snapshot.jobId
        streamTask = Task { @MainActor in
            do {
                for try await event in client.eventStream(jobId: jobId) {
                    if Task.isCancelled { break }
                    if let updated = APIClient.decodeSnapshot(from: event.rawPayload) {
                        player.updateSnapshot(updated)
                    }
                }
            } catch {
                // Network drop / job ended — playback continues with
                // whatever's in the queue already.
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

    private func reloadCurrentChapter() {
        guard let fulltext, let chapter = chapter(in: fulltext, at: player.currentChapterIndex) else {
            spans = []
            return
        }
        let computed = chapter.splitSentences()
        spans = computed
        sync.load(chapter: chapter, chapterDurationSeconds: player.durationSeconds)
        lastLoadedChapterIndex = player.currentChapterIndex
    }

    private func jumpTo(chapterIndex: Int) {
        player.play(snapshot: snapshot, startingAt: chapterIndex)
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

    private var currentChapterTitle: String {
        if let fulltext, let ch = chapter(in: fulltext, at: player.currentChapterIndex) {
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
}
#endif
