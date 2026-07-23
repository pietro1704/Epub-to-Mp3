import Foundation

/// Mirrors a single record returned by `GET /api/sessions`.
///
/// The Python backend (see `python_app/src/session_logger.py`) writes records
/// shaped like:
///   { timestamp, book_title, engine, chapters_converted,
///     duration_seconds, outcome, mode, ... }
///
/// We only decode the fields the iOS UI currently needs. Unknown fields are
/// ignored thanks to `Codable` default behaviour.
struct SessionRecord: Codable, Identifiable, Hashable {
    let timestamp: String
    let bookTitle: String
    let engine: String?
    let chaptersConverted: Int?
    let durationSeconds: Double?
    let outcome: String?
    let mode: String?

    /// Stable identifier for SwiftUI lists. The session log doesn't ship an
    /// explicit id, so the timestamp + title combo is used as a surrogate.
    var id: String { "\(timestamp)|\(bookTitle)" }

    enum CodingKeys: String, CodingKey {
        case timestamp
        case bookTitle = "book_title"
        case engine
        case chaptersConverted = "chapters_converted"
        case durationSeconds = "duration_seconds"
        case outcome
        case mode
    }
}

/// Envelope returned by `GET /api/sessions`.
struct SessionsResponse: Codable {
    let sessions: [SessionRecord]
    let count: Int
}

/// One line of an SSE stream payload coming from `/api/jobs/{id}/stream`.
/// The backend emits a JSON `JobSnapshot` per `data:` line; we surface the
/// raw text here for the slice and let later versions decode the full snapshot.
struct JobEvent: Identifiable, Hashable {
    let id = UUID()
    let receivedAt: Date
    let rawPayload: String
}
