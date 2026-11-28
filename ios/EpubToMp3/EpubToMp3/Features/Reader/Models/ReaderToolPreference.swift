import Foundation

enum ReaderTool: String, CaseIterable {
    case appearance, contents, search, footnotes, listen, voiceModels
    func isAvailable(hasFootnotes: Bool) -> Bool { self != .footnotes || hasFootnotes }

    var title: String {
        switch self {
        case .appearance: return L10n.string("reader.settings")
        case .contents: return L10n.string("reader.contents")
        case .search: return L10n.string("reader.search")
        case .footnotes: return L10n.string("reader.footnotes.title")
        case .listen: return L10n.string("player.play")
        case .voiceModels: return L10n.string("settings.voiceModels")
        }
    }
    var symbol: String {
        switch self {
        case .appearance: return "textformat.size"
        case .contents: return "list.bullet.indent"
        case .search: return "magnifyingglass"
        case .footnotes: return "text.append"
        case .listen: return "play"
        case .voiceModels: return "waveform"
        }
    }
    var accessibilityIdentifier: String {
        switch self {
        case .appearance: return "reader.settings.toggle"
        case .contents: return "reader.toc.toggle"
        case .search: return "reader.search"
        case .footnotes: return "reader.footnotes"
        case .listen: return "reader.listen"
        case .voiceModels: return "reader.voiceModels"
        }
    }
}

/// Wide readers show every tool that fits; the rest, in the same order, go to the "more" menu.
enum ReaderToolLayout {
    static func capacity(width: CGFloat, reserved: CGFloat, itemWidth: CGFloat) -> Int {
        max(1, Int((width - reserved) / itemWidth))
    }

    /// `capacity` counts toolbar slots, so the "more" button takes one when anything overflows.
    static func split(_ tools: [ReaderTool], capacity: Int) -> (inline: [ReaderTool], overflow: [ReaderTool]) {
        guard tools.count > capacity else { return (tools, []) }
        let visible = max(0, capacity - 1)
        return (Array(tools.prefix(visible)), Array(tools.dropFirst(visible)))
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
