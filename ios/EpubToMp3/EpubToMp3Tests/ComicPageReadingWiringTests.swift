import XCTest
@testable import EpubToMp3

/// Source-contract + unit tests for the P1 CBZ slice: comic pages render as
/// images (not text) in both reader controllers, the Listen action is
/// disabled for comics, and the shared import-type list replaced the 4
/// duplicated UTType lists. See `docs/reader-spec-comparison.md` P1 format
/// expansion.
final class ComicPageReadingWiringTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("EpubToMp3/\(relativePath)"),
            encoding: .utf8
        )
    }

    func testBookOpenScreenControllerRendersImagePagesForComics() throws {
        let source = try source("Features/Reader/Views/BookOpenScreenController.swift")

        XCTAssertTrue(source.contains("comicPageImageView"))
        XCTAssertTrue(source.contains("chapter.isImageOnly"))
    }

    func testMacReaderViewControllerRendersImagePagesForComics() throws {
        let source = try source("Features/Reader/Views/MacReaderViewController.swift")

        XCTAssertTrue(source.contains("comicPageImageView"))
        XCTAssertTrue(source.contains("chapter.isImageOnly"))
    }

    func testBookDetailScreensDisableListenForComics() throws {
        let ios = try source("Features/Library/Views/BookDetailScreenController.swift")
        let mac = try source("Features/Library/Views/MacBookDetailViewController.swift")

        XCTAssertTrue(ios.contains("book.fileType.supportsAudioConversion"))
        XCTAssertTrue(mac.contains("book.fileType.supportsAudioConversion"))
    }

    func testPickersUseSharedSupportedImportTypes() throws {
        for path in [
            "Features/Conversion/Views/ConvertScreenController.swift",
            "Features/Library/Views/LibraryScreenController.swift",
            "Features/Library/Views/MacLibraryViewController.swift",
            "Features/Reader/Views/BookOpenScreenController.swift",
        ] {
            let source = try source(path)
            XCTAssertTrue(
                source.contains("SupportedImportTypes.all"),
                "\(path) should use the shared SupportedImportTypes.all instead of a duplicated list"
            )
        }
    }

    func testEbookFulltextChapterExposesIsImageOnly() {
        let chapter = EbookFulltext.Chapter(
            index: 1, name: "Página 1", text: "", html: nil, css: nil, charCount: 0,
            segments: nil, contentKind: "images"
        )
        XCTAssertTrue(chapter.isImageOnly)

        let textChapter = EbookFulltext.Chapter(
            index: 1, name: "Ch", text: "hello", html: nil, css: nil, charCount: 5,
            segments: nil, contentKind: "text"
        )
        XCTAssertFalse(textChapter.isImageOnly)

        let legacyChapter = EbookFulltext.Chapter(
            index: 1, name: "Ch", text: "hello", html: nil, css: nil, charCount: 5, segments: nil
        )
        XCTAssertFalse(legacyChapter.isImageOnly, "Older cached payloads without contentKind must not be treated as image-only")
    }
}
