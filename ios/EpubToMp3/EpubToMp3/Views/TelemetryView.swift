import SwiftUI

@Observable
final class TelemetryViewModel {
    var rawJSON: String = ""
    var perEngine: [(engine: String, charsPerSecond: Double?, samples: Int?)] = []
    var isLoading: Bool = false
    var error: String? = nil
    var lastFetched: Date? = nil

    func reload(client: APIClient?) async {
        guard let client else {
            error = "No backend configured."
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
    @Environment(AppSettings.self) private var settings
    @State private var viewModel = TelemetryViewModel()

    private var client: APIClient? {
        settings.resolvedBaseURL.map(APIClient.init(baseURL:))
    }

    var body: some View {
        Form {
            Section("Engines") {
                if viewModel.isLoading && viewModel.perEngine.isEmpty {
                    ProgressView()
                } else if viewModel.perEngine.isEmpty {
                    Text("No telemetry samples yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.perEngine, id: \.engine) { row in
                        HStack {
                            Text(row.engine).font(.headline)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                if let cps = row.charsPerSecond {
                                    Text(String(format: "%.0f chars/s", cps))
                                        .font(.body.monospacedDigit())
                                } else {
                                    Text("—").foregroundStyle(.secondary)
                                }
                                if let n = row.samples {
                                    Text("\(n) chapters")
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
                    LabeledContent("Last fetched",
                                   value: when.formatted(date: .omitted, time: .standard))
                }
            }

            if !viewModel.rawJSON.isEmpty {
                Section("Raw payload") {
                    ScrollView(.horizontal) {
                        Text(viewModel.rawJSON)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Telemetry")
        .toolbar {
            ToolbarItem(placement: .compatPrimaryTrailing) {
                Button {
                    Task { await viewModel.reload(client: client) }
                } label: { Image(systemName: "arrow.clockwise") }
                .disabled(viewModel.isLoading)
            }
        }
        .task { await viewModel.reload(client: client) }
        .refreshable { await viewModel.reload(client: client) }
    }
}

#if DEBUG
#Preview("Telemetry") {
    NavigationStack { TelemetryView() }
        .environment(AppSettings())
}
#endif
