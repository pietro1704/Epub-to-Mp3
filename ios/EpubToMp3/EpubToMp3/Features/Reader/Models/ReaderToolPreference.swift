import Foundation

enum ReaderTool: String, CaseIterable {
    case appearance, contents, search, footnotes, listen
    var title: String {
        switch self {
        case .appearance: return L10n.string("reader.settings")
        case .contents: return L10n.string("reader.toc")
        case .search: return L10n.string("reader.search")
        case .footnotes: return L10n.string("reader.footnotes.title")
        case .listen: return L10n.string("player.play")
        }
    }
    var symbol: String {
        switch self {
        case .appearance: return "textformat.size"
        case .contents: return "list.bullet.indent"
        case .search: return "magnifyingglass"
        case .footnotes: return "text.append"
        case .listen: return "play"
        }
    }
    var accessibilityIdentifier: String {
        switch self {
        case .appearance: return "reader.settings.toggle"
        case .contents: return "reader.toc.toggle"
        case .search: return "reader.search"
        case .footnotes: return "reader.footnotes"
        case .listen: return "reader.listen"
        }
    }
}

struct ReaderToolPreference {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var recent: ReaderTool {
        get { defaults.string(forKey: "reader.recentTool.v1").flatMap(ReaderTool.init(rawValue:)) ?? .appearance }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "reader.recentTool.v1") }
    }
}
