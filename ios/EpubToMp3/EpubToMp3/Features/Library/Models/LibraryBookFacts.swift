import Foundation

/// What one Library card says about a book, built only from data the app already
/// stores. A fact that is not known is left out instead of being guessed.
struct LibraryBookFacts: Equatable, Sendable {
    enum Audio: Equatable, Sendable {
        case notConverted
        /// `total` is nil when nothing records how many chapters the book has.
        case partial(ready: Int, total: Int?)
        case complete

        init(ready: Int, total: Int?) {
            if ready <= 0 { self = .notConverted }
            else if let total, ready >= total { self = .complete }
            else { self = .partial(ready: ready, total: total) }
        }
    }

    /// A one-based place inside the book: a page for PDF, a chapter otherwise.
    struct Progress: Equatable, Sendable {
        let percent: Int
        let position: Int
        let total: Int

        /// `index` is zero-based and `fraction` is the part of that unit already read.
        init?(index: Int, total: Int, fraction: Double) {
            guard total > 0, index >= 0, index < total else { return nil }
            let within = fraction.isFinite ? min(max(fraction, 0), 1) : 0
            percent = Int(((Double(index) + within) / Double(total) * 100).rounded(.down))
            position = index + 1
            self.total = total
        }
    }

    /// Identity, progress, audio, added and last read.
    static let maximumLines = 5
    /// Height budget for a narrow card, where identity and audio each wrap once.
    static let maximumWrappedLines = maximumLines + 2

    let fileType: BookFileType
    var pageCount: Int?
    var chapterCount: Int?
    var progress: Progress?
    var audio: Audio?
    var audioSeconds: Double?
    var languageCode: String?
    var addedAt: Date
    var lastReadAt: Date?

    init(book: BookEntity) {
        fileType = book.fileType
        addedAt = book.addedAt
        let touched = book.lastInteractionAt
        lastReadAt = touched == .distantPast ? nil : touched
    }

    private var isPaged: Bool { fileType == .pdf }

    /// Card lines in display order; empty lines are never returned.
    func lines(bundle: Bundle? = nil, locale: Locale = .current, timeZone: TimeZone = .current) -> [String] {
        func text(_ key: String, _ arguments: any CVarArg...) -> String {
            String(format: L10n.string(key, bundle: bundle), locale: locale, arguments: arguments)
        }
        func counted(_ key: String, _ count: Int) -> String { text(count == 1 ? key + ".one" : key, count) }

        var identity = [fileType.rawValue.uppercased()]
        if isPaged, let pageCount { identity.append(counted("library.facts.pages", pageCount)) }
        if !isPaged, let chapterCount { identity.append(counted("library.facts.chapters", chapterCount)) }
        if let languageCode, !languageCode.isEmpty {
            identity.append(locale.localizedString(forIdentifier: languageCode) ?? languageCode)
        }
        var result = [identity.joined(separator: " · ")]

        if let progress {
            result.append(text(isPaged ? "library.facts.progressPage" : "library.facts.progressChapter",
                               progress.percent, progress.position, progress.total))
        }

        if fileType.supportsAudioConversion, let audio {
            var parts: [String]
            switch audio {
            case .notConverted: parts = [text("library.facts.audioNone")]
            case .complete: parts = [text("library.facts.audioComplete")]
            case let .partial(ready, total?): parts = [text("library.facts.audioPartial", ready, total)]
            case let .partial(ready, nil): parts = [counted("library.facts.audioReady", ready)]
            }
            if audio != .notConverted, let audioSeconds, audioSeconds >= 1 {
                let minutes = max(1, Int((audioSeconds / 60).rounded()))
                parts.append(minutes >= 60 ? text("library.facts.hoursMinutes", minutes / 60, minutes % 60)
                                           : text("library.facts.minutes", minutes))
            }
            result.append(parts.joined(separator: " · "))
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        result.append(text("library.facts.added", formatter.string(from: addedAt)))
        if let lastReadAt { result.append(text("library.facts.lastRead", formatter.string(from: lastReadAt))) }
        return result
    }
}
