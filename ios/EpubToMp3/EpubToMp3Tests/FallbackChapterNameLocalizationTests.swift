import XCTest
@testable import EpubToMp3

/// FALLBACK-CHAPTER-NAMES: chapters whose book supplies no title are named in the app language, not always in English.
final class FallbackChapterNameLocalizationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FallbackChapterNames-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        L10n.bundleOverrideForTesting = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func use(_ localization: String) throws {
        L10n.bundleOverrideForTesting = try XCTUnwrap(L10n.localizationBundle(localization), "\(localization).lproj missing")
    }

    func testFallbackNameFollowsTheAppLanguage() throws {
        try use("pt-BR")
        XCTAssertEqual(L10n.fallbackChapterName(3), "Capítulo 3")
        try use("es")
        XCTAssertEqual(L10n.fallbackChapterName(3), "Capítulo 3")
        try use("en")
        XCTAssertEqual(L10n.fallbackChapterName(3), "Chapter 3")
    }

    func testDownloadedFileOfAnUntitledChapterIsNamedInTheAppLanguage() throws {
        try use("pt-BR")
        let source = root.appendingPathComponent("converted.mp3")
        try Data(repeating: 1, count: 16).write(to: source)
        let mirror = DownloadedAudioFilesMirror(root: root.appendingPathComponent("Audiobooks", isDirectory: true))
        try mirror.publish(source, bookID: "book", bookTitle: "Livro", chapterIndex: 0, chapterTitle: "..")
        let files = try FileManager.default.contentsOfDirectory(atPath: mirror.root.appendingPathComponent("Livro").path)
            .filter { !$0.hasPrefix(".") }
        XCTAssertEqual(files, ["01 - Capítulo 1.mp3"])
    }

    func testEpubChapterWithoutAnyTitleIsNamedInTheAppLanguage() throws {
        try use("pt-BR")
        let url = try EpubFixture.createWithChapters(["<p>Texto sem título algum no capítulo.</p>"])
        defer { try? FileManager.default.removeItem(at: url) }
        let chapters = EpubFallbackParser.parse(url: url, bookId: "id").chapters
        XCTAssertEqual(chapters.first?.name, "Capítulo 1")
    }
}
