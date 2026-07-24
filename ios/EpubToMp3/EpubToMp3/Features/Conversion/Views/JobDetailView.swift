import SwiftUI

#if !os(iOS)
@MainActor
final class JobDetailViewModel: ObservableObject {
    @Published var snapshot: JobSnapshot?
    @Published var latestPayload: String = ""
    @Published var receivedCount: Int = 0
    @Published var isStreaming: Bool = false
    @Published var errorMessage: String?
    @Published var downloadProgressLabel: String?
    @Published var downloadState: DownloadProgress.State = .paused

    private var streamTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    let downloadManager = DownloadManager.shared

    func start(client: APIClient?, jobId: String) {
        stop()
        guard let client else {
            errorMessage = L10n.string("jobDetail.error.configureBackend")
            return
        }
        errorMessage = nil
        // 1. Pull initial snapshot via REST so the UI is populated even if
        //    the SSE stream takes time to deliver its first event.
        fetchTask = Task { @MainActor [weak self] in
            do {
                let snap = try await client.fetchJob(id: jobId)
                self?.snapshot = snap
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
        // 2. Subscribe to SSE for live updates.
        isStreaming = true
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in client.eventStream(jobId: jobId) {
                    if Task.isCancelled { break }
                    let decoded = APIClient.decodeSnapshot(from: event.rawPayload)
                    await MainActor.run {
                        self.latestPayload = event.rawPayload
                        self.receivedCount += 1
                        if let decoded { self.snapshot = decoded }
                    }
                }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
            await MainActor.run { self.isStreaming = false }
        }
    }

    func stop() {
        streamTask?.cancel(); streamTask = nil
        fetchTask?.cancel(); fetchTask = nil
        downloadTask?.cancel(); downloadTask = nil
        isStreaming = false
    }

    func downloadAll(baseURL: URL?) {
        guard let snapshot else { return }
        downloadState = .downloading
        downloadTask = Task { [weak self] in
            guard let self else { return }
            await self.downloadManager.enqueueAll(snapshot: snapshot, baseURL: baseURL)
            for await progress in await self.downloadManager.watchProgress(jobId: snapshot.jobId) {
                await MainActor.run {
                    self.downloadProgressLabel =
                        "\(progress.completedChapters)/\(progress.totalChapters) — \(progress.state.rawValue)"
                    self.downloadState = progress.state
                }
                if progress.state == .completed || progress.state == .failed || progress.state == .cancelled { break }
            }
        }
    }

    func cancelDownloads() {
        guard let jobId = snapshot?.jobId else { return }
        downloadTask?.cancel()
        Task { await downloadManager.cancel(jobId: jobId) }
        downloadState = .cancelled
    }

    func clearDownloads() {
        guard let jobId = snapshot?.jobId else { return }
        downloadTask?.cancel()
        Task { await downloadManager.clearDownloadedBook(jobId: jobId) }
        downloadState = .paused
        downloadProgressLabel = nil
    }
}
#endif

#if os(iOS)
struct JobDetailView: View {
    let jobId: String

    var body: some View {
        EmptyView()
    }
}
#else
struct JobDetailView: View {
    let jobId: String
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var viewModel = JobDetailViewModel()
    @State private var showingPlayer = false

    private var client: APIClient? {
        settings.resolvedBaseURL.map(APIClient.init(baseURL:))
    }

    var body: some View {
        Form {
            Section(L10n.string("jobDetail.job")) {
                CompatLabeledContent(L10n.string("jobDetail.id"), value: jobId).font(.footnote.monospaced())
                if let snap = viewModel.snapshot {
                    CompatLabeledContent(L10n.string("jobDetail.state"), value: snap.state)
                    if let title = snap.bookTitle { CompatLabeledContent(L10n.string("jobDetail.book"), value: title) }
                    if let pct = snap.progressPercent {
                        CompatLabeledContent(L10n.string("jobDetail.progress"), value: String(format: "%.0f%%", pct))
                    }
                }
                CompatLabeledContent(L10n.string("jobDetail.streaming")) {
                    if viewModel.isStreaming {
                        Label(L10n.string("jobDetail.live"), systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                    } else {
                        Text(localized: "jobDetail.idle").foregroundStyle(.secondary)
                    }
                }
                CompatLabeledContent(L10n.string("jobDetail.eventsReceived"), value: "\(viewModel.receivedCount)")
            }

            if let chapters = viewModel.snapshot?.playableChapters, !chapters.isEmpty {
                Section(L10n.string("player.chapters")) {
                    ForEach(chapters) { chapter in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(chapter.displayTitle).font(.body)
                                if let url = chapter.downloadUrl {
                                    Text(url).font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if chapter.isCompleted {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        showingPlayer = true
                    } label: {
                        Label(L10n.string("player.play"), systemImage: "play.circle.fill")
                    }
                    Button {
                        viewModel.downloadAll(baseURL: settings.resolvedBaseURL)
                    } label: {
                        Label(L10n.string("jobDetail.downloadAll"), systemImage: "arrow.down.circle")
                    }
                    if viewModel.downloadState == .downloading {
                        Button(role: .destructive) {
                            viewModel.cancelDownloads()
                        } label: {
                            Label(L10n.string("chapterList.cancelDownloads"), systemImage: "xmark.circle")
                        }
                    }
                    if viewModel.downloadState == .completed {
                        Button(role: .destructive) {
                            viewModel.clearDownloads()
                        } label: {
                            Label(L10n.string("chapterList.removeDownloads"), systemImage: "trash")
                        }
                    }
                    NavigationLink {
                        LogsView(jobId: jobId)
                    } label: {
                        Label(L10n.string("jobDetail.openLogs"), systemImage: "doc.text.magnifyingglass")
                    }
                    if let dlLabel = viewModel.downloadProgressLabel {
                        Text(dlLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let err = viewModel.errorMessage {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section(L10n.string("jobDetail.latestEventPayload")) {
                if viewModel.latestPayload.isEmpty {
                    Text(localized: "jobDetail.waitingFirstEvent").foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal) {
                        Text(viewModel.latestPayload)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle(L10n.string("jobDetail.title"))
        .compatInlineNavigationTitle()
        .onAppear {
            guard !isSwiftUIPreview else { return }
            viewModel.start(client: client, jobId: jobId)
        }
        .onDisappear { viewModel.stop() }
        .compatFullScreenCover(isPresented: $showingPlayer) {
            if let snap = viewModel.snapshot {
                // sheet / fullScreenCover roots a new view tree —
                // re-inject the environments that PlayerReaderView
                // (and its `TocDrawer` sheet) read so SwiftUI doesn't
                // crash with "missing Environment Object".
                PlayerReaderView(snapshot: snap, backendBaseURL: settings.resolvedBaseURL)
                    .environmentObject(settings)
                    .environmentObject(library)
            }
        }
    }
}
#endif

#if DEBUG && !os(iOS)
#Preview("JobDetail — empty state") {
    CompatNavigationStack {
        JobDetailView(jobId: "preview-job-id")
    }
    .environmentObject(AppSettings())
    .environmentObject(LibraryStore.previewEmpty)
    .environmentObject(AudioPlayer())
    .environmentObject(PlaybackClock())
}
#endif
