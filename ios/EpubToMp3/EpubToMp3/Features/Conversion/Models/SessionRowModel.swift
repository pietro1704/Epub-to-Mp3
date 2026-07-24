import Foundation

/// Pure row model for the sessions (jobs history) list, shared by the
/// UIKit list-config collection view (`JobsListCollectionView`) and unit
/// tests. Kept Foundation-only so it's testable off-device — mirrors
/// `ChapterListRowModel`/`LibraryGridLayoutMetrics`.
struct SessionRowModel: Equatable {
    enum OutcomeState: Equatable {
        case success, partial, failed, unknown
    }

    let id: String
    let title: String
    let outcomeText: String?
    let outcomeState: OutcomeState
    let engineText: String?
    let chaptersText: String?
    let timestampText: String

    static func make(from session: SessionRecord) -> SessionRowModel {
        SessionRowModel(
            id: session.id,
            title: session.bookTitle,
            outcomeText: session.outcome.map { $0.capitalized },
            outcomeState: outcomeState(for: session.outcome),
            engineText: (session.engine?.isEmpty == false) ? session.engine : nil,
            chaptersText: session.chaptersConverted.map { L10n.string("jobs.chaptersAbbrev", $0) },
            timestampText: String(session.timestamp.prefix(19))
        )
    }

    static func rows(from sessions: [SessionRecord]) -> [SessionRowModel] {
        sessions.map(make(from:))
    }

    /// Secondary line combining engine / chapter count / timestamp, the
    /// same fields the SwiftUI `SessionRow` lays out in its trailing `HStack`.
    var detailText: String {
        [engineText, chaptersText, timestampText].compactMap { $0 }.joined(separator: " · ")
    }

    private static func outcomeState(for outcome: String?) -> OutcomeState {
        switch outcome?.lowercased() {
        case "success": return .success
        case "partial": return .partial
        case "failed": return .failed
        default: return .unknown
        }
    }
}
