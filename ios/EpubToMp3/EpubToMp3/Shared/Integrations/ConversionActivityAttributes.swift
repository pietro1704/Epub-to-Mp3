import Foundation

public enum ConversionActivityPhase: String, Codable, Hashable, Sendable {
    case preparing, converting, cancelling, completed, cancelled, failed

    public var localizationKey: String { "liveActivity.\(rawValue)" }
    public var isTerminal: Bool { self == .completed || self == .cancelled || self == .failed }
}

/// Shared wire payload. Optional additions preserve activities created by earlier versions.
public struct ConversionActivityProgress: Codable, Hashable, Sendable {
    public var chaptersDone: Int
    public var chaptersTotal: Int
    public var currentChapterName: String?
    public var progressPercent: Double?
    public var phase: ConversionActivityPhase?
    public var bookTitle: String?

    public init(chaptersDone: Int, chaptersTotal: Int, currentChapterName: String? = nil,
                progressPercent: Double? = nil, phase: ConversionActivityPhase = .converting,
                bookTitle: String? = nil) {
        self.chaptersDone = max(0, chaptersDone)
        self.chaptersTotal = max(0, chaptersTotal)
        self.currentChapterName = currentChapterName
        self.progressPercent = progressPercent
        self.phase = phase
        self.bookTitle = bookTitle
    }

    public var progressFraction: Double {
        if phase == .completed { return 1 }
        if let progressPercent, progressPercent.isFinite { return min(1, max(0, progressPercent / 100)) }
        guard chaptersTotal > 0 else { return 0 }
        return min(1, max(0, Double(chaptersDone) / Double(chaptersTotal)))
    }

    public var statusLabel: String {
        guard chaptersTotal > 0 else {
            return progressPercent?.isFinite == true ? "\(Int(progressFraction * 100))%" : "…"
        }
        return "\(min(max(0, chaptersDone), chaptersTotal)) / \(chaptersTotal)"
    }

    public var statusLocalizationKey: String { (phase ?? .converting).localizationKey }
}

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

@available(iOS 16.1, *)
public struct ConversionActivityAttributes: ActivityAttributes {
    public typealias ContentState = ConversionActivityProgress

    public let bookTitle: String
    public let bookId: String
    public let jobID: String?

    public init(bookTitle: String, bookId: String, jobID: String? = nil) {
        self.bookTitle = bookTitle
        self.bookId = bookId
        self.jobID = jobID
    }
}
#endif
