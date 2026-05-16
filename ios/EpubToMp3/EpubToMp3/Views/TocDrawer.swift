import SwiftUI

/// Slide-over chapter list. Shown from `PlayerReaderView` toolbar.
/// Tapping a chapter jumps both the audio queue (`onJump`) and the
/// reader pane to that chapter.
struct TocDrawer: View {
    let fulltext: EbookFulltext?
    let snapshot: JobSnapshot
    let currentChapterIndex: Int
    let onJump: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CompatNavigationStack {
            List {
                if let fulltext, !fulltext.chapters.isEmpty {
                    ForEach(fulltext.chapters) { chapter in
                        chapterRow(
                            title: chapter.displayTitle,
                            index: chapter.index - 1, // backend is 1-based
                            charCount: chapter.charCount,
                            isCurrent: (chapter.index - 1) == currentChapterIndex,
                            audioReady: audioReady(forZeroBasedIndex: chapter.index - 1)
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
                            isCurrent: chapter.index == currentChapterIndex,
                            audioReady: chapter.downloadUrl != nil
                        )
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Chapters")
            .compatInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
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
                            Text("\(charCount) chars")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        if !audioReady {
                            Label("text only", systemImage: "doc.text")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Currently playing")
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
