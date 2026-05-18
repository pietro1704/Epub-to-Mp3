// Shared between the main app target (which starts/ends/updates Live Activities)
// and the EpubToMp3Widget target (which renders them via ActivityConfiguration).
// Both targets compile this file as part of their own module — ActivityKit
// resolves the activity by Codable identity, not nominal cross-module identity.
#if canImport(ActivityKit) && os(iOS)
import ActivityKit

/// Triggered by `WidgetDataSync.startConversionActivity` when a job enters
/// running. Explicitly ended by `WidgetDataSync.endConversionActivity` when
/// the job finishes / fails.
public struct ConversionActivityAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable {
        public var chaptersDone: Int
        public var chaptersTotal: Int
        public var currentChapterName: String?

        public init(chaptersDone: Int, chaptersTotal: Int, currentChapterName: String? = nil) {
            self.chaptersDone = chaptersDone
            self.chaptersTotal = chaptersTotal
            self.currentChapterName = currentChapterName
        }

        public var progressFraction: Double {
            guard chaptersTotal > 0 else { return 0 }
            return Double(chaptersDone) / Double(chaptersTotal)
        }

        public var statusLabel: String {
            "\(chaptersDone) / \(chaptersTotal)"
        }
    }

    public let bookTitle: String
    public let bookId: String

    public init(bookTitle: String, bookId: String) {
        self.bookTitle = bookTitle
        self.bookId = bookId
    }
}
#endif
