import SwiftUI

#if os(iOS)
struct TelemetryView: View {
    var body: some View {
        EmptyView()
    }
}
#else
@MainActor
final class TelemetryViewModel: ObservableObject {
    @Published var rawJSON: String = ""
    @Published var perEngine: [(engine: String, charsPerSecond: Double?, samples: Int?)] = []
    @Published var isLoading: Bool = false
    @Published var error: String? = nil
    @Published var lastFetched: Date? = nil

    func reload(client: APIClient?) async {
        guard let client else {
            error = L10n.string("logs.error.noBackend")
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let data = try await client.fetchTelemetry()
            rawJSON = (String(data: data, encoding: .utf8) ?? "")
                .prefix(8000).description
            perEngine = Self.summarise(data: data)
            lastFetched = Date()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// Pull a small "engine → chars/s" summary out of whatever shape the
    /// backend serves today. Defensive: any JSON layout that doesn't
    /// match yields an empty list (the raw payload is still rendered).
    static func summarise(data: Data) -> [(engine: String, charsPerSecond: Double?, samples: Int?)] {
        guard let any = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var out: [(String, Double?, Int?)] = []

        if let dict = any as? [String: Any],
           let perEngine = dict["perEngine"] as? [String: Any] {
            for (engine, raw) in perEngine {
                if let entry = raw as? [String: Any] {
                    let cps = entry["charsPerSecond"] as? Double
                    let n = entry["totalChapters"] as? Int ?? entry["samples"] as? Int
                    out.append((engine, cps, n))
                }
            }
        } else if let arr = any as? [[String: Any]] {
            for entry in arr {
                if let engine = entry["engine"] as? String {
                    let cps = entry["charsPerSecond"] as? Double
                    let n = entry["totalChapters"] as? Int ?? entry["samples"] as? Int
                    out.append((engine, cps, n))
                }
            }
        }

        return out.sorted { ($0.1 ?? 0) > ($1.1 ?? 0) }
    }
}

struct TelemetryView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var viewModel = TelemetryViewModel()

    private var client: APIClient? {
        settings.resolvedBaseURL.map(APIClient.init(baseURL:))
    }

    /// `Date.formatted(date:time:)` exists on iOS 15 / macOS 12 but
    /// `time: .standard` returns a localised time string we can also
    /// build with `DateFormatter` on Big Sur. Returns "HH:mm:ss" in
    /// the user locale.
    private static func formatTimestamp(_ when: Date) -> String {
        if #available(iOS 15, macOS 12, *) {
            return when.formatted(date: .omitted, time: .standard)
        }
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f.string(from: when)
    }

    var body: some View {
        Form {
            Section(L10n.string("telemetry.engines")) {
                if viewModel.isLoading && viewModel.perEngine.isEmpty {
                    ProgressView()
                } else if viewModel.perEngine.isEmpty {
                    Text(localized: "telemetry.noSamples").foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.perEngine, id: \.engine) { row in
                        HStack {
                            Text(row.engine).font(.headline)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                if let cps = row.charsPerSecond {
                                    Text(L10n.string("telemetry.charsPerSecond", String(format: "%.0f", cps)))
                                        .font(.body.monospacedDigit())
                                } else {
                                    Text(verbatim: "—").foregroundStyle(.secondary)
                                }
                                if let n = row.samples {
                                    Text(L10n.string("telemetry.chaptersCount", n))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            if let err = viewModel.error {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            if let when = viewModel.lastFetched {
                Section {
                    // `Date.formatted(...)` (the FormatStyle API) requires
                    // iOS 15 / macOS 12, so we keep `.formatted` but route
                    // through a thin formatter on macOS 11.
                    CompatLabeledContent(L10n.string("telemetry.lastFetched"),
                                         value: Self.formatTimestamp(when))
                }
            }

            if !viewModel.rawJSON.isEmpty {
                Section(L10n.string("telemetry.rawPayload")) {
                    ScrollView(.horizontal) {
                        Text(viewModel.rawJSON)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle(L10n.string("settings.telemetry"))
        .toolbar {
            ToolbarItem(placement: .compatPrimaryTrailing) {
                Button {
                    Task { await viewModel.reload(client: client) }
                } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel(L10n.string("telemetry.refresh"))
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

#if DEBUG
#Preview("Telemetry") {
    CompatNavigationStack { TelemetryView() }
        .environmentObject(AppSettings())
}
#endif
#endif
