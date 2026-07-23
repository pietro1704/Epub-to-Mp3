import SwiftUI

@MainActor
final class JobsListViewModel: ObservableObject {
    @Published var sessions: [SessionRecord] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func reload(client: APIClient?) async {
        guard let client else {
            errorMessage = L10n.string("jobDetail.error.configureBackend")
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            sessions = try await client.fetchSessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct JobsListView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var viewModel = JobsListViewModel()

    private var client: APIClient? {
        settings.resolvedBaseURL.map(APIClient.init(baseURL:))
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.sessions.isEmpty {
                ProgressView().controlSize(.large)
            } else if let error = viewModel.errorMessage, viewModel.sessions.isEmpty {
                CompatContentUnavailableView(L10n.string("jobs.cannotReachBackend"),
                                             systemImage: "wifi.exclamationmark",
                                             description: Text(error))
            } else if viewModel.sessions.isEmpty {
                CompatContentUnavailableView(L10n.string("jobs.noConversions"),
                                             systemImage: "tray",
                                             description: Text(localized: "jobs.noConversionsDescription"))
            } else {
                List(viewModel.sessions) { session in
                    // `NavigationLink(value:)` requires the `.navigationDestination`
                    // value-based router (iOS 16+). On iOS 15 we fall back to
                    // the classic destination-based push.
                    if #available(iOS 16, macOS 13, *) {
                        NavigationLink(value: session) {
                            SessionRow(session: session)
                        }
                    } else {
                        NavigationLink {
                            JobDetailView(jobId: session.bookTitle)
                        } label: {
                            SessionRow(session: session)
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.string("jobs.title"))
        .compatJobsDestination()
        .toolbar {
            ToolbarItem(placement: .compatPrimaryTrailing) {
                Button {
                    Task { await viewModel.reload(client: client) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(L10n.string("jobs.refresh"))
                .disabled(viewModel.isLoading)
            }
        }
        .task {
            guard !isSwiftUIPreview else { return }
            await viewModel.reload(client: client)
        }
        .refreshable { await viewModel.reload(client: client) }
    }
}

struct SessionRow: View {
    let session: SessionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.bookTitle).font(.headline).lineLimit(2)
            HStack(spacing: 8) {
                if let outcome = session.outcome {
                    Text(outcome.capitalized)
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(outcomeColor(outcome).opacity(0.15))
                        .foregroundStyle(outcomeColor(outcome))
                        .clipShape(Capsule())
                }
                if let engine = session.engine, !engine.isEmpty {
                    Text(engine).font(.caption).foregroundStyle(.secondary)
                }
                if let chapters = session.chaptersConverted {
                    Text(L10n.string("jobs.chaptersAbbrev", chapters)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(session.timestamp.prefix(19))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func outcomeColor(_ outcome: String) -> Color {
        switch outcome.lowercased() {
        case "success": return .green
        case "partial": return .orange
        case "failed":  return .red
        default:        return .secondary
        }
    }
}

#Preview("SessionRow — success") {
    List {
        SessionRow(session: SessionRecord(
            timestamp: "2026-05-08T10:23:45",
            bookTitle: "Foundation",
            engine: "edge",
            chaptersConverted: 24,
            durationSeconds: 1800,
            outcome: "success",
            mode: "cli"))
        SessionRow(session: SessionRecord(
            timestamp: "2026-05-07T22:01:11",
            bookTitle: "O Hobbit",
            engine: "piper",
            chaptersConverted: 19,
            durationSeconds: 4200,
            outcome: "partial",
            mode: "web"))
        SessionRow(session: SessionRecord(
            timestamp: "2026-05-07T08:15:00",
            bookTitle: "Metro 2033",
            engine: "piper",
            chaptersConverted: 0,
            durationSeconds: 12,
            outcome: "failed",
            mode: "cli"))
    }
}

/// `.navigationDestination(for:)` is iOS 16 / macOS 13. The legacy
/// path uses inline `NavigationLink(destination:)` above; this
/// modifier only applies on the modern OSes.
private extension View {
    @ViewBuilder
    func compatJobsDestination() -> some View {
        if #available(iOS 16, macOS 13, *) {
            self.navigationDestination(for: SessionRecord.self) { session in
                // Sessions don't carry a job id (they're a historical log), so for
                // this slice we let users tap and observe the live SSE for an
                // arbitrary id derived from the session's title — tweak in v2.
                JobDetailView(jobId: session.bookTitle)
            }
        } else {
            self
        }
    }
}

#Preview("JobsList — empty") {
    CompatNavigationStack { JobsListView() }
        .environmentObject(AppSettings())
}
