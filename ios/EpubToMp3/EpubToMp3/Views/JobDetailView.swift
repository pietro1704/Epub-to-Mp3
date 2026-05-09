import SwiftUI

@Observable
final class JobDetailViewModel {
    var snapshot: JobSnapshot?
    var latestPayload: String = ""
    var receivedCount: Int = 0
    var isStreaming: Bool = false
    var errorMessage: String?
    var downloadProgressLabel: String?

    private var streamTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    let downloadManager = DownloadManager()

    func start(client: APIClient?, jobId: String) {
        stop()
        guard let client else {
            errorMessage = "Configure backend URL in Settings."
            return
        }
        errorMessage = nil
        // 1. Pull initial snapshot via REST so the UI is populated even if
        //    the SSE stream takes time to deliver its first event.
        fetchTask = Task { [weak self] in
            do {
                let snap = try await client.fetchJob(id: jobId)
                await MainActor.run { self?.snapshot = snap }
            } catch {
                await MainActor.run { self?.errorMessage = error.localizedDescription }
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
        downloadManager.enqueueAll(snapshot: snapshot, baseURL: baseURL)
        downloadTask = Task { [weak self] in
            guard let self else { return }
            for await progress in self.downloadManager.watchProgress(jobId: snapshot.jobId) {
                await MainActor.run {
                    self.downloadProgressLabel =
                        "\(progress.completedChapters)/\(progress.totalChapters) — \(progress.state.rawValue)"
                }
                if progress.state == .completed || progress.state == .failed { break }
            }
        }
    }
}

struct JobDetailView: View {
    let jobId: String
    @Environment(AppSettings.self) private var settings
    @State private var viewModel = JobDetailViewModel()
    @State private var showingPlayer = false

    private var client: APIClient? {
        settings.resolvedBaseURL.map(APIClient.init(baseURL:))
    }

    var body: some View {
        Form {
            Section("Job") {
                LabeledContent("ID", value: jobId).font(.footnote.monospaced())
                if let snap = viewModel.snapshot {
                    LabeledContent("State", value: snap.state)
                    if let title = snap.bookTitle { LabeledContent("Book", value: title) }
                    if let pct = snap.progressPercent {
                        LabeledContent("Progress", value: String(format: "%.0f%%", pct))
                    }
                }
                LabeledContent("Streaming") {
                    if viewModel.isStreaming {
                        Label("Live", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                    } else {
                        Text("Idle").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Events received", value: "\(viewModel.receivedCount)")
            }

            if let chapters = viewModel.snapshot?.playableChapters, !chapters.isEmpty {
                Section("Chapters") {
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
                        Label("Play", systemImage: "play.circle.fill")
                    }
                    Button {
                        viewModel.downloadAll(baseURL: settings.resolvedBaseURL)
                    } label: {
                        Label("Download all", systemImage: "arrow.down.circle")
                    }
                    NavigationLink {
                        LogsView(jobId: jobId)
                    } label: {
                        Label("Open logs", systemImage: "doc.text.magnifyingglass")
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

            Section("Latest event payload") {
                if viewModel.latestPayload.isEmpty {
                    Text("Waiting for first event…").foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal) {
                        Text(viewModel.latestPayload)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Job detail")
        .compatInlineNavigationTitle()
        .onAppear { viewModel.start(client: client, jobId: jobId) }
        .onDisappear { viewModel.stop() }
        .compatFullScreenCover(isPresented: $showingPlayer) {
            if let snap = viewModel.snapshot {
                // sheet / fullScreenCover roots a new view tree —
                // re-inject the environments that PlayerReaderView
                // (and its `TocDrawer` sheet) read so SwiftUI doesn't
                // crash with "missing Environment Object".
                PlayerReaderView(snapshot: snap, backendBaseURL: settings.resolvedBaseURL)
                    .environment(settings)
            }
        }
    }
}

#Preview("JobDetail — empty state") {
    NavigationStack {
        JobDetailView(jobId: "preview-job-id")
    }
    .environment(AppSettings())
}
