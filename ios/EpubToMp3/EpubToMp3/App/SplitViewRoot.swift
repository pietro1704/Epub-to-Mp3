import Foundation

/// Destinations used by the native macOS sidebar.
enum SplitNavMode: String, Hashable, CaseIterable, Identifiable {
    case reader
    case library
    case jobs
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .reader: return L10n.string("nav.read")
        case .library: return L10n.string("nav.library")
        case .jobs: return L10n.string("nav.conversions")
        case .settings: return L10n.string("nav.settings")
        }
    }

    var systemImage: String {
        switch self {
        case .reader: return "text.book.closed"
        case .library: return "books.vertical"
        case .jobs: return "arrow.triangle.2.circlepath"
        case .settings: return "gearshape"
        }
    }
}

enum SplitViewSidebarMiniPlayerPolicy {
    static func shouldShow(
        navMode: SplitNavMode,
        hasPlayableBook: Bool,
        isShowingPlayerReaderDetail: Bool
    ) -> Bool {
        guard hasPlayableBook else { return false }
        switch navMode {
        case .reader: return false
        case .library: return !isShowingPlayerReaderDetail
        case .jobs, .settings: return true
        }
    }
}

/// Compatibility token for old source-level callers. Native AppKit owns the
/// real split view in `MacAppKitRootController`.
struct SplitViewRoot {
    init() {}
}
