import SwiftUI

/// Slide-over chapter list. Shown from `PlayerReaderView` toolbar.
/// Tapping a chapter jumps both the audio queue (`onJump`) and the
/// reader pane to that chapter.
struct TocDrawer: View {
    let fulltext: EbookFulltext?
    let snapshot: JobSnapshot
    /// Currently-playing audio chapter index (0-based). Pass a negative
    /// value when no audio is mounted on the player.
    let currentChapterIndex: Int
    /// Currently-visible reader chapter index (0-based). Optional —
    /// callers that don't track a separate scroll cursor can omit it.
    /// When provided, a chapter is marked "current" if EITHER cursor
    /// (audio OR reading) lands on it. When no audio is mounted, the
    /// reading cursor wins so the marker still tracks the user.
    let readingChapterIndex: Int?
    let onJump: (Int) -> Void

    init(
        fulltext: EbookFulltext?,
        snapshot: JobSnapshot,
        currentChapterIndex: Int,
        readingChapterIndex: Int? = nil,
        onJump: @escaping (Int) -> Void
    ) {
        self.fulltext = fulltext
        self.snapshot = snapshot
        self.currentChapterIndex = currentChapterIndex
        self.readingChapterIndex = readingChapterIndex
        self.onJump = onJump
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CompatNavigationStack {
            List {
                if let fulltext, !fulltext.chapters.isEmpty {
                    ForEach(fulltext.chapters) { chapter in
                        let zeroBased = chapter.index - 1 // backend is 1-based
                        chapterRow(
                            title: chapter.displayTitle,
                            index: zeroBased,
                            charCount: chapter.charCount,
                            isCurrent: isCurrent(zeroBasedIndex: zeroBased),
                            audioReady: audioReady(forZeroBasedIndex: zeroBased)
                        )
                    }
                } else {
                    // Fallback: drive the TOC from the snapshot's
                    // playable chapters when the fulltext payload
                    // hasn't loaded yet.
                    ForEach(snapshot.playableChapters) { chapter in
                        chapterRow(
                            title: chapter.displayTitle,
                            index: chapter.index,
                            charCount: chapter.chars,
                            isCurrent: isCurrent(zeroBasedIndex: chapter.index),
                            audioReady: chapter.downloadUrl != nil
                        )
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(L10n.string("player.chapters"))
            .compatInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("player.close")) { dismiss() }
                }
            }
        }
    }

    private func chapterRow(
        title: String,
        index: Int,
        charCount: Int?,
        isCurrent: Bool,
        audioReady: Bool
    ) -> some View {
        Button {
            onJump(index)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(.secondary, lineWidth: 1)
                        .frame(width: 28, height: 28)
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        if let charCount {
                            Text(L10n.string("toc.charsCount", charCount))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        if !audioReady {
                            Label(L10n.string("toc.textOnly"), systemImage: "doc.text")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if isCurrent {
                    // Speaker icon when audio is mounted and matches
                    // this row; reading-cursor icon when no audio is
                    // mounted yet — same accent so visual weight is
                    // identical.
                    let audioActive = currentChapterIndex >= 0
                    let onAudio = audioActive && currentChapterIndex == index
                    Image(systemName: onAudio
                          ? "speaker.wave.2.fill"
                          : "book.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel(onAudio
                                            ? L10n.string("toc.currentlyPlaying")
                                            : L10n.string("toc.currentlyReading"))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("toc.chapter.\(index)")
    }

    private func audioReady(forZeroBasedIndex idx: Int) -> Bool {
        snapshot.playableChapters.contains { $0.index == idx && $0.downloadUrl != nil }
    }

    /// A chapter is "current" when:
    ///  - audio is mounted and the audio cursor matches it, OR
    ///  - the reader cursor matches it (when supplied by the caller).
    /// When no audio is mounted (`currentChapterIndex < 0`), the
    /// reading cursor is the sole signal — otherwise the speaker icon
    /// would never appear before playback begins.
    private func isCurrent(zeroBasedIndex idx: Int) -> Bool {
        let audioActive = currentChapterIndex >= 0
        let audioMatch = audioActive && currentChapterIndex == idx
        let readingMatch = readingChapterIndex.map { $0 == idx } ?? false
        if audioActive {
            return audioMatch || readingMatch
        }
        return readingMatch
    }
}

#if DEBUG
#Preview("TocDrawer — fulltext") {
    TocDrawer(
        fulltext: EbookFulltext.previewSample,
        snapshot: JobSnapshot.previewSample,
        currentChapterIndex: 1,
        onJump: { _ in }
    )
}

#Preview("TocDrawer — fallback (no fulltext)") {
    TocDrawer(
        fulltext: nil,
        snapshot: JobSnapshot.previewSample,
        currentChapterIndex: 0,
        onJump: { _ in }
    )
}
#endif
