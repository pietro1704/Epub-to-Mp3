import Foundation
import Combine

@MainActor
final class TelemetryViewModel: ObservableObject {
    @Published var rawJSON = ""
    @Published var perEngine: [(engine: String, charsPerSecond: Double?, samples: Int?)] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var lastFetched: Date?

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
            rawJSON = String(data: data, encoding: .utf8)?.prefix(8000).description ?? ""
            perEngine = Self.summarise(data: data)
            lastFetched = Date()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    static func summarise(data: Data) -> [(engine: String, charsPerSecond: Double?, samples: Int?)] {
        guard let any = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var rows: [(String, Double?, Int?)] = []
        if let dict = any as? [String: Any], let engines = dict["perEngine"] as? [String: Any] {
            for (engine, raw) in engines {
                guard let entry = raw as? [String: Any] else { continue }
                rows.append((engine, entry["charsPerSecond"] as? Double, entry["totalChapters"] as? Int ?? entry["samples"] as? Int))
            }
        } else if let entries = any as? [[String: Any]] {
            for entry in entries {
                guard let engine = entry["engine"] as? String else { continue }
                rows.append((engine, entry["charsPerSecond"] as? Double, entry["totalChapters"] as? Int ?? entry["samples"] as? Int))
            }
        }
        return rows.sorted { ($0.1 ?? 0) > ($1.1 ?? 0) }
    }
}
