import SwiftUI

@Observable
final class JobDetailViewModel {
    var latestPayload: String = ""
    var receivedCount: Int = 0
    var isStreaming: Bool = false
    var errorMessage: String?

    private var streamTask: Task<Void, Never>?

    func start(client: APIClient?, jobId: String) {
        stop()
        guard let client else {
            errorMessage = "Configure backend URL in Settings."
            return
        }
        errorMessage = nil
        isStreaming = true
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in client.eventStream(jobId: jobId) {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        self.latestPayload = event.rawPayload
                        self.receivedCount += 1
                    }
                }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
            await MainActor.run { self.isStreaming = false }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }
}

struct JobDetailView: View {
    let jobId: String
    @Environment(AppSettings.self) private var settings
    @State private var viewModel = JobDetailViewModel()

    private var client: APIClient? {
        settings.resolvedBaseURL.map(APIClient.init(baseURL:))
    }

    var body: some View {
        Form {
            Section("Job") {
                LabeledContent("ID", value: jobId).font(.footnote.monospaced())
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

            if let err = viewModel.errorMessage {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section {
                if viewModel.isStreaming {
                    Button(role: .destructive) { viewModel.stop() } label: {
                        Label("Stop streaming", systemImage: "stop.circle")
                    }
                } else {
                    Button {
                        viewModel.start(client: client, jobId: jobId)
                    } label: {
                        Label("Start streaming", systemImage: "play.circle")
                    }
                }
            }
        }
        .navigationTitle("Job detail")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.start(client: client, jobId: jobId) }
        .onDisappear { viewModel.stop() }
    }
}
