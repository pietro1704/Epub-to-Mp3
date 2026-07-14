import Foundation

/// Mirrors the JSON contract emitted by the Python backend's
/// `GET /api/jobs/{id}` and `GET /api/jobs/{id}/stream` (SSE) endpoints.
///
/// Source of truth: `python_app/server.py` — `class JobStatus(BaseModel)`
/// (around line 2170) plus `_job_status_payload` (around line 1244).
///
/// IMPORTANT: the backend already serialises in **camelCase** at the JSON
/// layer (`jobId`, `chapterProgress`, `bookTitle`, …) — it is *not*
/// snake_case. The slice-2 prompt assumed snake_case; we match the actual
/// wire format here. Do not introduce CodingKeys translations or you will
/// silently break decoding.
///
/// Fields we don't yet need on iOS are intentionally omitted — `Codable`
/// ignores unknown JSON keys.
struct JobSnapshot: Codable, Equatable, Identifiable {

    /// One entry from `chapterProgress[]`. Backend writes these in
    /// `_server_conversion_helpers.py::advance_chapter_progress` and the
    /// recovery path in `server.py::_restore_job_from_outputs`.
    struct Chapter: Codable, Equatable, Hashable, Identifiable {
        let index: Int
        let name: String?
        let status: String?
        let downloadUrl: String?
        let chars: Int?
        let charsProcessed: Int?
        let progressRatio: Double?
        let durationSeconds: Double?
        let startedAt: Double?
        let completedAt: Double?

        var id: Int { index }

        var displayTitle: String {
            if let name, !name.isEmpty { return name }
            return L10n.string("player.chapter", index + 1)
        }

        var isCompleted: Bool {
            (status?.lowercased() == "completed") || (downloadUrl?.isEmpty == false && progressRatio.map { $0 >= 0.999 } == true)
        }
    }

    /// One entry from `outputs[]` — top-level files produced by the job
    /// (full ZIP, conversion.log, plus per-chapter MP3s on the recovery
    /// path). Schema: `_asset_entry()` in `server.py`.
    struct OutputAsset: Codable, Equatable, Hashable, Identifiable {
        let name: String
        let url: String
        let sizeBytes: Int?

        var id: String { name }

        var isMP3: Bool { name.lowercased().hasSuffix(".mp3") }
        var isZip: Bool { name.lowercased().hasSuffix(".zip") }
    }

    let jobId: String
    let state: String
    let bookTitle: String?
    let bookAuthor: String?
    let coverUrl: String?
    let coverMimeType: String?
    let engine: String?
    let voice: String?
    let language: String?
    let progressPercent: Double?
    let chaptersTotal: Int?
    let chaptersCompleted: Int?
    let chapterProgress: [Chapter]?
    let outputs: [OutputAsset]?
    let logUrl: String?
    let error: String?
    let lastActivityAt: Double?

    var id: String { jobId }

    /// All MP3 outputs known to the snapshot, in stable order. Prefers
    /// per-chapter `chapterProgress` entries (richer metadata) and falls
    /// back to the flat `outputs[]` MP3 list if `chapterProgress` is empty.
    var playableChapters: [Chapter] {
        if let progress = chapterProgress, !progress.isEmpty {
            return progress
                .filter { $0.downloadUrl != nil }
                .sorted { $0.index < $1.index }
        }
        guard let outputs else { return [] }
        return outputs.enumerated().compactMap { idx, asset in
            guard asset.isMP3 else { return nil }
            // Strip "NNN - " numeric prefix and ".mp3" suffix so the user sees
            // the human-readable chapter title, not a filename or a hash.
            let stem = (asset.name as NSString).deletingPathExtension
            // Require at least one space on each side of the dash so we never
            // strip hyphens that are part of the real title (e.g. "42-Plain").
            let humanName = stem.replacingOccurrences(
                of: #"^\d+\s+[-–]\s+"#, with: "", options: .regularExpression
            )
            return Chapter(
                index: idx,
                name: humanName.isEmpty ? nil : humanName,
                status: "completed",
                downloadUrl: asset.url,
                chars: nil,
                charsProcessed: nil,
                progressRatio: 1.0,
                durationSeconds: nil,
                startedAt: nil,
                completedAt: nil
            )
        }
    }

    var isTerminal: Bool {
        let s = state.lowercased()
        return s == "finished" || s == "failed" || s == "cancelled"
    }
}
