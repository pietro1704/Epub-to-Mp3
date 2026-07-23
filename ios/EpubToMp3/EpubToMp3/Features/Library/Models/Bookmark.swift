import Foundation

enum HighlightColor: String, Codable, CaseIterable, Identifiable {
    case yellow
    case blue
    case green
    case pink
    case orange

    var id: String { rawValue }
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
