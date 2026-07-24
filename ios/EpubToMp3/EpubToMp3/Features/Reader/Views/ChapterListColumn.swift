import SwiftUI

/// Middle column of the `NavigationSplitView`: shows the chapter list
/// for the currently-selected book. Three states:
///
/// 1. Book has a `lastJobId` and the backend is reachable → fetch the
///    `JobSnapshot` and render `playableChapters` as a selectable list.
/// 2. Book has no audio yet → empty-state CTA pointing the user back
///    to `BookOpenView` (the conversion bootstrap lives there).
/// 3. Fetch failed / no backend → small inline error with retry.
///
/// Chapter selection writes through `selectedChapterIndex` so the
/// detail column can mount `PlayerReaderView` at the right index.
struct ChapterListColumn: View {
    let book: BookEntity
    @Binding var selectedChapterIndex: Int?

    @EnvironmentObject private var settings: AppSettings

    @State private var snapshot: JobSnapshot?
    @State private var loadError: String?
    @State private var isLoading: Bool = false
    @State private var fetchTask: Task<Void, Never>?
    @State private var showRemoveDownloadsAlert = false
    @State private var showClearCacheAlert = false

    var body: some View {
        Group {
            if let snapshot {
                chapterList(snapshot: snapshot)
            } else if isLoading {
                ProgressView(L10n.string("chapterList.loadingChapters"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                errorView(message: loadError)
            } else {
                noAudioYet
            }
        }
        .navigationTitle(book.resolvedTitle)
        .compatInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(role: .destructive) {
                        showRemoveDownloadsAlert = true
                    } label: {
                        Label(L10n.string("chapterList.removeDownloads"), systemImage: "trash")
                    }
                    Button(role: .destructive) {
                        showClearCacheAlert = true
                    } label: {
                        Label(L10n.string("chapterList.clearTextCache"), systemImage: "xmark.bin")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(L10n.string("common.moreOptions"))
            }
        }
        .alert(L10n.string("chapterList.removeDownloads"), isPresented: $showRemoveDownloadsAlert) {
            Button(L10n.string("common.delete"), role: .destructive) {
                if let jobId = book.lastJobId {
                    Task { await DownloadManager.shared.clearDownloadedBook(jobId: jobId) }
                }
            }
            Button(L10n.string("common.cancel"), role: .cancel) {}
        } message: {
            Text(localized: "chapterList.removeDownloadsMessage")
        }
        .alert(L10n.string("chapterList.clearTextCache"), isPresented: $showClearCacheAlert) {
            Button(L10n.string("common.delete"), role: .destructive) {
                clearTextCache()
            }
            Button(L10n.string("common.cancel"), role: .cancel) {}
        } message: {
            Text(localized: "chapterList.clearTextCacheMessage")
        }
        .task(id: book.id) {
            await reload()
        }
        .onDisappear { fetchTask?.cancel() }
    }

    private func clearTextCache() {
        let root = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("epub2mp3-tts/\(book.id)", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Subviews

    private func chapterList(snapshot: JobSnapshot) -> some View {
        let chapters = snapshot.playableChapters
        return Group {
            if chapters.isEmpty {
                CompatContentUnavailableView(
                    L10n.string("chapterList.noChaptersYet"),
                    systemImage: "headphones.slash",
                    description: Text(localized: "chapterList.noChaptersYetDescription")
                )
            } else {
                #if canImport(UIKit)
                ChapterListCollectionView(
                    rows: ChapterListRowModel.rows(from: chapters),
                    selectedChapterIndex: $selectedChapterIndex
                )
                #else
                List(selection: $selectedChapterIndex) {
                    ForEach(chapters) { chapter in
                        ChapterListRow(chapter: chapter)
                            .tag(chapter.index as Int?)
                    }
                }
                .listStyle(.inset)
                #endif
            }
        }
    }

    private var noAudioYet: some View {
        VStack(spacing: 12) {
            CompatContentUnavailableView(
                L10n.string("nowPlaying.noAudioYet"),
                systemImage: "waveform.slash",
                description: Text(localized: "chapterList.noAudioYetDescription")
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Button(L10n.string("common.retry")) {
                Task { await reload() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Fetch

    @MainActor
    private func reload() async {
        // Reset selection whenever the book changes.
        selectedChapterIndex = nil
        snapshot = nil
        loadError = nil
        #if DEBUG
        if isSwiftUIPreview {
            // Preview canvas: skip network entirely.
            snapshot = book.id == "preview-2" ? JobSnapshot.previewSample : nil
            return
        }
        #endif
        guard let jobId = book.lastJobId else {
            // No previous conversion known. Stay in "no audio" state.
            return
        }
        guard let baseURL = settings.resolvedBaseURL else {
            // No backend URL configured AND no sidecar URL yet. This
            // is normal on first launch / iOS — the audio runtime
            // boots in-process and may not be ready yet. Don't surface
            // an error: the reader is already on screen and the user
            // doesn't need chapter-level audio metadata to read.
            return
        }
        isLoading = true
        fetchTask?.cancel()
        fetchTask = Task { @MainActor in
            defer { self.isLoading = false }
            do {
                let client = APIClient(baseURL: baseURL)
                let snap = try await client.fetchJob(id: jobId)
                if Task.isCancelled { return }
                self.snapshot = snap
            } catch {
                if Task.isCancelled { return }
                self.loadError = error.localizedDescription
            }
        }
        await fetchTask?.value
    }
}

/// One chapter row — index, name, completion state.
private struct ChapterListRow: View {
    let chapter: JobSnapshot.Chapter

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: chapter.isCompleted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(chapter.isCompleted ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.displayTitle)
                    .font(.subheadline)
                    .lineLimit(2)
                if let chars = chapter.chars, chars > 0 {
                    Text(L10n.string("toc.charsCount", chars))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let duration = chapter.durationSeconds, duration > 0 {
                Text(formatDuration(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel({
            var parts = [chapter.displayTitle]
            if chapter.isCompleted { parts.append(L10n.string("chapterList.completed")) }
            if let duration = chapter.durationSeconds, duration > 0 {
                parts.append(formatDuration(duration))
            }
            return parts.joined(separator: ", ")
        }())
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

#if DEBUG
#Preview("ChapterList — preview-2") {
    ChapterListColumn(
        book: BookEntity(
            id: "preview-2",
            title: "Metro 2033",
            author: "Dmitry Glukhovsky",
            bookmark: Data(),
            displayFilename: "metro2033.epub",
            addedAt: Date(),
            lastOpenedAt: nil,
            lastChapterIndex: nil,
            lastPositionSeconds: nil,
            coverPNG: nil,
            lastJobId: "preview-job-id",
            cachedOffline: false
        ),
        selectedChapterIndex: .constant(nil)
    )
    .environmentObject(AppSettings())
    .environmentObject(LibraryStore.previewPopulated)
}

#Preview("ChapterList — no audio") {
    ChapterListColumn(
        book: BookEntity(
            id: "preview-3",
            title: "O Hobbit",
            author: "Tolkien",
            bookmark: Data(),
            displayFilename: "o_hobbit.epub",
            addedAt: Date(),
            lastOpenedAt: nil,
            lastChapterIndex: nil,
            lastPositionSeconds: nil,
            coverPNG: nil,
            lastJobId: nil,
            cachedOffline: false
        ),
        selectedChapterIndex: .constant(nil)
    )
    .environmentObject(AppSettings())
    .environmentObject(LibraryStore.previewPopulated)
}
#endif
