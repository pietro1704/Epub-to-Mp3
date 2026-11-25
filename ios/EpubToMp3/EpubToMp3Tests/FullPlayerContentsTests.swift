#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class FullPlayerContentsTests: XCTestCase {
    func testPlayerOnlyContentsKeepsDownloadAvailableForAnUnconvertedChapter() async throws {
        let bookID = "PlayerContents-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: bookID))
        defer { defaults.removePersistentDomain(forName: bookID) }
        let book = BookEntity(id: bookID, title: "Player contents fixture", bookmark: Data([1]),
                              displayFilename: "contents.epub", addedAt: Date())
        let chapters: [EbookFulltext.Chapter] = (1...3).map { index in
            let text = "Chapter \(index)."
            return .init(index: index, name: "Chapter \(index)", text: text,
                         html: nil, css: nil, charCount: text.count, segments: nil)
        }
        let toc: [EbookFulltext.TocEntry] = chapters.map { chapter in
            .init(title: "Authored chapter \(chapter.index)", level: 0,
                  chapterIndex: chapter.index, children: [])
        }
        LocalFulltextCache.save(.init(jobId: bookID, bookTitle: book.title, bookAuthor: nil,
                                     chapters: chapters, toc: toc), bookId: bookID)
        defer { LocalFulltextCache.evict(bookId: bookID) }
        defaults.set(try JSONEncoder().encode([book]), forKey: "library")
        let library = LibraryStore(defaults: defaults, defaultsKey: "library")
        XCTAssertEqual(library.books.map(\.id), [bookID])

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        let previousWindow = scene?.windows.first(where: \.isKeyWindow)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        player.location.bindPlayingBook(bookID, chapter: 0)
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            player.stop()
            previousWindow?.makeKey()
        }
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(bookID).mp3")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try LegacyAudioImportFixture.audio.write(to: audioURL)
        func makeSnapshot(jobID: String, indices: [Int]) -> JobSnapshot {
            let chapters = indices.map { index in
                JobSnapshot.Chapter(index: index, name: "Chapter \(index + 1)", status: "completed",
                    downloadUrl: audioURL.absoluteString, chars: nil, charsProcessed: nil,
                    progressRatio: 1, durationSeconds: nil, startedAt: nil, completedAt: nil)
            }
            return JobSnapshot(jobId: jobID, state: "finished", bookTitle: nil, bookAuthor: nil,
                coverUrl: nil, coverMimeType: nil, engine: nil, voice: nil, language: nil,
                progressPercent: 100, chaptersTotal: 3, chaptersCompleted: chapters.count,
                chapterProgress: chapters, outputs: nil, logUrl: nil, error: nil,
                lastActivityAt: nil, chapterIndexBase: 0)
        }
        let snapshot = makeSnapshot(jobID: "embedded-\(bookID)", indices: [0])
        player.setSnapshot(snapshot)
        let expanded = FullPlayerScreenController(player: player,
            library: library, playerPresentation: PlayerPresentation(defaults: defaults),
            settings: AppSettings(defaults: defaults),
            onStartListening: { XCTFail("Unconverted chapter must keep a Download action") })
        window.rootViewController = expanded
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        expanded.perform(NSSelectorFromString("tocTapped"))
        for _ in 0..<250 {
            try await Task.sleep(nanoseconds: 20_000_000)
            if expanded.presentedViewController != nil { break }
        }
        let sheet = try XCTUnwrap(expanded.presentedViewController)
        let contents = try contentsController(in: sheet)
        XCTAssertEqual(contents.tableView.numberOfRows(inSection: 0), 3)
        let unconverted = IndexPath(row: 2, section: 0)
        let row = contents.tableView(contents.tableView, cellForRowAt: unconverted)
        XCTAssertEqual(row.accessibilityLabel, "Authored chapter 3")
        XCTAssertEqual(row.selectionStyle, .none)
        XCTAssertNil(contents.tableView(contents.tableView, willSelectRowAt: unconverted))
        XCTAssertEqual(row.accessoryView?.accessibilityLabel, L10n.string("player.downloadChapter"))
        contents.tableView(contents.tableView, didSelectRowAt: unconverted)

        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            expanded.presentedViewController == nil
        }, object: nil)
        dismissed.isInverted = true
        await fulfillment(of: [dismissed], timeout: 1.5)
        XCTAssertTrue(expanded.presentedViewController === sheet)
        XCTAssertEqual(player.snapshot?.jobId, snapshot.jobId)
        XCTAssertEqual(player.currentChapterIndex, 0)

        let unrelated = makeSnapshot(jobID: "unrelated-\(bookID)", indices: [2])
        player.setSnapshot(unrelated)
        XCTAssertNil(contents.tableView(contents.tableView, willSelectRowAt: unconverted))
        contents.tableView(contents.tableView, didSelectRowAt: unconverted)
        XCTAssertTrue(expanded.presentedViewController === sheet)
        XCTAssertEqual(player.snapshot?.jobId, unrelated.jobId)
        XCTAssertFalse(player.hasLoadedAudioQueue)
        XCTAssertEqual(contents.tableView.cellForRow(at: unconverted)?.selectionStyle, UITableViewCell.SelectionStyle.none)

        let updated = makeSnapshot(jobID: snapshot.jobId, indices: [0, 2])
        player.setSnapshot(updated)
        for _ in 0..<75 {
            try await Task.sleep(nanoseconds: 20_000_000)
            contents.tableView.layoutIfNeeded()
            if contents.tableView.cellForRow(at: unconverted)?.selectionStyle == .default { break }
        }
        XCTAssertEqual(contents.tableView.cellForRow(at: unconverted)?.selectionStyle, .default,
                       "The open TOC should reflect chapters added to the same job.")
        XCTAssertEqual(contents.tableView(contents.tableView, willSelectRowAt: unconverted), unconverted)
        contents.tableView(contents.tableView, didSelectRowAt: unconverted)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(player.snapshot?.jobId, updated.jobId)
        XCTAssertEqual(player.currentChapterIndex, 1)
        XCTAssertTrue(player.hasLoadedAudioQueue)
    }

    private func contentsController(in sheet: UIViewController?) throws -> TocScreenController {
        let navigation = try XCTUnwrap(sheet as? UINavigationController)
        let controller = try XCTUnwrap(navigation.topViewController as? TocScreenController)
        controller.loadViewIfNeeded()
        return controller
    }
}
#endif
