#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

/// Streamed narration has no final audio length yet, so the lock screen timeline needs the reader's
/// per-chapter estimates. A PDF must provide them as an EPUB does.
@MainActor
final class PDFNowPlayingTimelineTests: XCTestCase {
    func testOpenPDFProvidesADurationEstimateForEveryNarrationChapter() async throws {
        let suite = "pdf-now-playing-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let source = try PdfFixture.createMultiPage(pages: [
            (heading: "First", body: "A synthetic first chapter with enough words to last a moment."),
            (heading: "Second", body: "A synthetic second chapter that also has some words.")])
        let library = LibraryStore(defaults: defaults, defaultsKey: "library", importDirectory: directory)
        let book = try library.importBook(from: source)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let controller = BookOpenScreenController(
            book: book, library: library, settings: AppSettings(defaults: defaults),
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            player: player, sessionDefaults: defaults)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        let previousWindow = scene?.windows.first(where: \.isKeyWindow)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
            player.stop()
            ReaderProgressStore.evict(bookId: book.id)
            defaults.removePersistentDomain(forName: suite)
            for url in [source, directory] { try? FileManager.default.removeItem(at: url) }
        }
        for _ in 0..<100 where controller.playbackChapterCatalog.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let catalog = controller.playbackChapterCatalog
        XCTAssertFalse(catalog.isEmpty, "The PDF must finish loading")

        let estimates = controller.playbackChapterEstimates
        for chapter in catalog {
            XCTAssertGreaterThan(estimates[chapter.index] ?? 0, 0,
                                 "Chapter \(chapter.index) needs a duration for the lock screen timeline")
        }
    }
}
#endif
