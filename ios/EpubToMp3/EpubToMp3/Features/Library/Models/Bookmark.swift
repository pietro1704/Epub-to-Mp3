import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum HighlightColor: String, Codable, CaseIterable, Identifiable {
    case yellow
    case blue
    case green
    case pink
    case orange

    var id: String { rawValue }

    /// Background tint used to repaint a saved highlight's resolved
    /// `NSRange` back into the rendered reader text (see
    /// `ReaderTextHighlight`).
    var platformColor: PlatformColor {
        switch self {
        case .yellow: return PlatformColor.systemYellow.withAlphaComponent(0.35)
        case .blue: return PlatformColor.systemBlue.withAlphaComponent(0.35)
        case .green: return PlatformColor.systemGreen.withAlphaComponent(0.35)
        case .pink: return PlatformColor.systemPink.withAlphaComponent(0.35)
        case .orange: return PlatformColor.systemOrange.withAlphaComponent(0.35)
        }
    }
}

struct Bookmark: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let bookId: String
    let chapterIndex: Int
    let chapterTitle: String
    let startChar: Int
    let endChar: Int
    let selectedText: String
    var note: String?
    var color: HighlightColor
    let createdAt: Date

    var isHighlight: Bool { !selectedText.isEmpty }
}
