import SwiftUI

@MainActor
final class LogsViewModel: ObservableObject {
    @Published var content: String = ""
    @Published var isLoading: Bool = false
    @Published var error: String? = nil
    @Published var autoRefresh: Bool = true

    private var pollingTask: Task<Void, Never>?

    func start(client: APIClient?, jobId: String) {
        stop()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.fetchOnce(client: client, jobId: jobId)
                if !self.autoRefresh { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func fetchOnce(client: APIClient?, jobId: String) async {
        guard let client else {
            await MainActor.run { self.error = "No backend configured." }
            return
        }
        await MainActor.run { self.isLoading = true; self.error = nil }
        do {
            let text = try await client.fetchJobLog(id: jobId)
            await MainActor.run {
                self.content = text
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.error = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                self.isLoading = false
            }
        }
    }
}

struct LogsView: View {
    let jobId: String
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var viewModel = LogsViewModel()

    private var client: APIClient? {
        settings.resolvedBaseURL.map(APIClient.init(baseURL:))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if viewModel.content.isEmpty && !viewModel.isLoading {
                    Text("No log output yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                } else {
                    Text(viewModel.content)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("log-bottom")
                }
            }
            .background(.black.opacity(0.85))
            .foregroundStyle(.green)
            .compatOnChange(of: viewModel.content) { _ in
                if viewModel.autoRefresh {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("log-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle("Logs · \(jobId.prefix(8))")
        .compatInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .compatPrimaryTrailing) {
                Toggle(isOn: Binding(
                    get: { viewModel.autoRefresh },
                    set: { newValue in
                        viewModel.autoRefresh = newValue
                        if newValue { viewModel.start(client: client, jobId: jobId) }
                    }
                )) {
                    Image(systemName: viewModel.autoRefresh ? "pause.circle" : "play.circle")
                }
                .toggleStyle(.button)
                .accessibilityLabel(viewModel.autoRefresh ? "Pause auto-refresh" : "Resume auto-refresh")
            }
        }
        .onAppear {
            guard !isSwiftUIPreview else { return }
            viewModel.start(client: client, jobId: jobId)
        }
        .onDisappear { viewModel.stop() }
        .overlay(alignment: .bottom) {
            if let err = viewModel.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.red.opacity(0.85))
                    .cornerRadius(6)
                    .padding()
            }
        }
    }
}

#if DEBUG
#Preview("Logs") {
    CompatNavigationStack {
        LogsView(jobId: "preview-job-id")
    }
    .environmentObject(AppSettings())
}
#endif
