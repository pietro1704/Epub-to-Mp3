import Foundation
import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class DownloadedAudioFilesMirrorTests: XCTestCase {
    private var root: URL!
    private var mirror: DownloadedAudioFilesMirror!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadsMirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        mirror = DownloadedAudioFilesMirror(root: root.appendingPathComponent("Audiobooks", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func audio(_ name: String, _ byte: UInt8) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: byte, count: 16).write(to: url)
        return url
    }

    private func visible(_ folder: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: mirror.root.appendingPathComponent(folder).path)
            .filter { !$0.hasPrefix(".") }.sorted()
    }

    private func folders() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: mirror.root.path).sorted()
    }

    func testChaptersAppearUnderTheBookTitleWithReadableNames() throws {
        let source = try audio("converted.mp3", 1)
        try mirror.publish(source, bookID: "book-a", bookTitle: "Dom Casmurro", chapterIndex: 0, chapterTitle: "Do título")
        try mirror.publish(source, bookID: "book-a", bookTitle: "Dom Casmurro", chapterIndex: 11, chapterTitle: "Na varanda")
        XCTAssertEqual(try folders(), ["Dom Casmurro"])
        XCTAssertEqual(try visible("Dom Casmurro"), ["01 - Do título.mp3", "12 - Na varanda.mp3"])
        XCTAssertEqual(try Data(contentsOf: mirror.root.appendingPathComponent("Dom Casmurro/12 - Na varanda.mp3")),
                       Data(repeating: 1, count: 16))
        XCTAssertEqual(try Data(contentsOf: source), Data(repeating: 1, count: 16), "The store's file is only read")
        XCTAssertTrue(DownloadedAudioFilesMirror.isMirrorFolder(mirror.root.appendingPathComponent("Dom Casmurro")))
    }

    func testANewDownloadOfAChapterReplacesItsCopyEvenWhenTheTitleChanged() throws {
        try mirror.publish(try audio("old.mp3", 1), bookID: "book", bookTitle: "Book", chapterIndex: 2, chapterTitle: "Old name")
        try mirror.publish(try audio("new.mp3", 2), bookID: "book", bookTitle: "Renamed later", chapterIndex: 2, chapterTitle: "New name")
        XCTAssertEqual(try folders(), ["Book"], "A book keeps the folder it was first given")
        XCTAssertEqual(try visible("Book"), ["03 - New name.mp3"])
        XCTAssertEqual(try Data(contentsOf: mirror.root.appendingPathComponent("Book/03 - New name.mp3")),
                       Data(repeating: 2, count: 16))
    }

    func testTwoBooksWithTheSameTitleNeverShareAFolderOrOverwriteEachOther() throws {
        try mirror.publish(try audio("a.mp3", 1), bookID: "a", bookTitle: "Poems", chapterIndex: 0, chapterTitle: "One")
        try mirror.publish(try audio("b.mp3", 2), bookID: "b", bookTitle: "Poems", chapterIndex: 0, chapterTitle: "One")
        XCTAssertEqual(try folders(), ["Poems", "Poems (2)"])
        XCTAssertEqual(try Data(contentsOf: mirror.root.appendingPathComponent("Poems/01 - One.mp3")), Data(repeating: 1, count: 16))
        XCTAssertEqual(try Data(contentsOf: mirror.root.appendingPathComponent("Poems (2)/01 - One.mp3")), Data(repeating: 2, count: 16))
        try mirror.withdrawBook(bookID: "a")
        XCTAssertEqual(try folders(), ["Poems (2)"])
    }

    func testRemovalDeletesOnlyTheCopiesThisTypeCreated() throws {
        let source = try audio("converted.mp3", 1)
        try mirror.publish(source, bookID: "book", bookTitle: "Book", chapterIndex: 0, chapterTitle: "One")
        try mirror.publish(source, bookID: "book", bookTitle: "Book", chapterIndex: 1, chapterTitle: "Two")
        let folder = mirror.root.appendingPathComponent("Book")
        // The listener's own file, and a name that collides with a future copy.
        try Data("mine".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        try Data("mine".utf8).write(to: folder.appendingPathComponent("03 - Three.mp3"))
        try mirror.publish(source, bookID: "book", bookTitle: "Book", chapterIndex: 2, chapterTitle: "Three")
        XCTAssertEqual(try visible("Book"), ["01 - One.mp3", "02 - Two.mp3", "03 - Three (2).mp3", "03 - Three.mp3", "notes.txt"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("03 - Three.mp3")), Data("mine".utf8))

        try mirror.withdraw(bookID: "book", chapterIndex: 0)
        XCTAssertEqual(try visible("Book"), ["02 - Two.mp3", "03 - Three (2).mp3", "03 - Three.mp3", "notes.txt"])
        try mirror.withdraw(bookID: "book", chapterIndex: 9)
        try mirror.withdraw(bookID: "unknown", chapterIndex: 0)
        try mirror.withdrawBook(bookID: "book")
        XCTAssertEqual(try visible("Book"), ["03 - Three.mp3", "notes.txt"], "The listener's files stay")
        XCTAssertFalse(DownloadedAudioFilesMirror.isMirrorFolder(folder))
    }

    func testACopyTheListenerDeletedIsNotAnErrorAndTheEmptyFolderGoesAway() throws {
        let source = try audio("converted.mp3", 1)
        try mirror.publish(source, bookID: "book", bookTitle: "Book", chapterIndex: 0, chapterTitle: "One")
        try FileManager.default.removeItem(at: mirror.root.appendingPathComponent("Book/01 - One.mp3"))
        try mirror.withdraw(bookID: "book", chapterIndex: 0)
        XCTAssertEqual(try folders(), [])
    }

    func testWithdrawAllLeavesFoldersItDidNotCreate() throws {
        let source = try audio("converted.mp3", 1)
        try mirror.publish(source, bookID: "a", bookTitle: "A", chapterIndex: 0, chapterTitle: "One")
        try mirror.publish(source, bookID: "b", bookTitle: "B", chapterIndex: 0, chapterTitle: "One")
        let legacy = mirror.root.appendingPathComponent("job-123/chapters", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data([1]).write(to: legacy.appendingPathComponent("Chapter.mp3"))
        try mirror.withdrawAll()
        XCTAssertEqual(try folders(), ["job-123"])
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("Chapter.mp3")), Data([1]))
    }

    func testTitlesCannotEscapeTheFolderOrHideTheFile() throws {
        let source = try audio("converted.mp3", 1)
        try mirror.publish(source, bookID: "book", bookTitle: "../../Escape: a/b", chapterIndex: 0, chapterTitle: "..")
        try mirror.publish(source, bookID: "book", bookTitle: "ignored", chapterIndex: 1, chapterTitle: " .hidden/\u{0}name\n")
        XCTAssertEqual(try folders(), ["Escape a b"])
        XCTAssertEqual(try visible("Escape a b"), ["01 - Chapter 1.mp3", "02 - hidden name.mp3"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
                       ["Audiobooks", "converted.mp3"], "Nothing is written outside the mirror root")
        XCTAssertEqual(DownloadedAudioFilesMirror.component("   ", fallback: "Audiobook"), "Audiobook")
        XCTAssertLessThanOrEqual(
            DownloadedAudioFilesMirror.component(String(repeating: "é", count: 400), fallback: "x").utf8.count, 180)
    }
}
