import AVFoundation
import Foundation
import PDFKit

/// Gathers `LibraryBookFacts` from what the app already stored for a book. It
/// never converts or parses a book, and runs off the main thread.
struct LibraryBookFactsReader: @unchecked Sendable {
    var defaults: UserDefaults = .standard
    var artifacts: LocalAudioArtifactStore = .shared
    var convertedSnapshot: @Sendable (String) -> JobSnapshot? = {
        RustConversionCoordinator.persistedSnapshot(jobID: $0)
    }
    var chapterCount: @Sendable (String) -> Int? = { LocalFulltextCache.storedChapterCount(bookId: $0) }
    var pageCount: @Sendable (BookEntity) -> Int? = { LibraryBookMeasurements.shared.pageCount(of: $0) }
    var audioSeconds: @Sendable (URL) -> Double? = { LibraryBookMeasurements.shared.seconds(of: $0) }

    func facts(for book: BookEntity) async -> LibraryBookFacts {
        var facts = LibraryBookFacts(book: book)
        facts.languageCode = BookLanguageSummaries(defaults: defaults)
            .language(bookID: book.id, corrections: BookLanguageCorrections(defaults: defaults))
        if book.fileType == .pdf {
            facts.pageCount = pageCount(book)
            if let total = facts.pageCount,
               let page = ReaderProgressStore.savedPDFPage(bookId: book.id, defaults: defaults) {
                facts.progress = .init(index: page, total: total, fraction: 1)
            }
        } else {
            facts.chapterCount = chapterCount(book.id)
            if let total = facts.chapterCount,
               let entry = ReaderProgressStore.read(bookId: book.id, defaults: defaults) {
                facts.progress = .init(index: entry.chapterIndex, total: total, fraction: entry.offsetFraction)
            }
        }
        guard book.fileType.supportsAudioConversion else { return facts }
        let retained: JobSnapshot?
        do {
            retained = try await artifacts.playableSnapshot(bookID: book.id, engine: "", voice: "", language: nil)
        } catch {
            // Unreadable audio records are unknown, not "never converted".
            NSLog("Library audio facts unavailable: %@", error.localizedDescription)
            return facts
        }
        let converted = book.lastJobId.flatMap(convertedSnapshot)
        let audio = LocalAudioPlaybackRestoration.snapshot(
            bookID: book.id, conversionJobID: book.lastJobId, retained: retained, converted: converted)
        let playable = audio?.playableChapters ?? []
        let ready = playable.filter { ($0.textOffset ?? 0) == 0 }.count
        // PDF audio chapters are not pages, so only the conversion can say how many there are.
        facts.audio = .init(ready: ready, total: audio?.sourceChaptersTotal ?? facts.chapterCount)
        let durations = playable.compactMap { chapter in
            chapter.downloadUrl.flatMap(URL.init(string:)).flatMap(audioSeconds)
        }
        // A sum with a missing chapter would understate the book, so it is left out.
        if !playable.isEmpty, durations.count == playable.count { facts.audioSeconds = durations.reduce(0, +) }
        return facts
    }
}

/// Remembers the two measurements that need a file to be opened.
final class LibraryBookMeasurements: @unchecked Sendable {
    static let shared = LibraryBookMeasurements()
    private let lock = NSLock()
    private var pages: [String: Int] = [:]
    private var durations: [String: Double] = [:]

    func pageCount(of book: BookEntity) -> Int? {
        if let known = lock.withLock({ pages[book.id] }) { return known }
        guard let url = try? LibraryBookmarkAccess.resolveBookBookmark(book.bookmark).url else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let count = PDFDocument(url: url)?.pageCount, count > 0 else { return nil }
        lock.withLock { pages[book.id] = count }
        return count
    }

    func seconds(of url: URL) -> Double? {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        let key = "\(url.path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let known = lock.withLock({ durations[key] }) { return known }
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return nil }
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        lock.withLock { durations[key] = seconds }
        return seconds
    }
}
