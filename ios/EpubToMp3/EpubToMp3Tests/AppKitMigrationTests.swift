import XCTest
@testable import EpubToMp3
#if os(macOS)
import AppKit

@MainActor
final class AppKitMigrationTests: XCTestCase {
    func testMacLibraryInstallsNativeCollectionAndAccessibleImportControl() throws {
        let suite = "native-library-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MacLibraryViewController(library: LibraryStore(defaults: defaults),
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            onOpenBook: { _ in }, onDownloadBook: { _ in }, onConvertBook: { _ in })
        controller.loadViewIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(controller.view)
        XCTAssertNotNil(views.compactMap { $0 as? NSCollectionView }.first)
        let add = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "library.add"
        })
        XCTAssertNotNil(add.target)
        XCTAssertNotNil(add.action)
    }

    func testReaderInstallsNativeTextSurfaceAndToolbar() throws {
        let harness = try NativeReaderTestHarness(chapters: [NativeReaderTestHarness.chapter("Native text")])
        harness.installTeardown(in: self)
        harness.showChapter(0)
        XCTAssertTrue(harness.composition.contentScrollView.documentView === harness.composition.textView)
        XCTAssertEqual(harness.composition.textView.string, "Native text")
        XCTAssertFalse(harness.composition.textView.isEditable)
        XCTAssertTrue(harness.composition.textView.isSelectable)
        XCTAssertTrue(harness.composition.toolbar.isDescendant(of: harness.controller.view))
    }

    func testLibraryGridPreservesStableIdentityWhileSortingAndFiltering() {
        let books = [BookEntity(id: "z", title: "Zebra", bookmark: Data(), displayFilename: "z.epub", addedAt: .distantPast),
                     BookEntity(id: "a", title: "Alpha", bookmark: Data(), displayFilename: "a.epub", addedAt: .distantPast)]
        var model = LibraryGridModel(books: books, sortMode: .title)
        XCTAssertEqual(model.arrangedIdentifiers(), ["a", "z"])
        model.searchQuery = "ZEBRA"
        XCTAssertEqual(model.arrangedIdentifiers(), ["z"])
        model.searchQuery = "missing"
        XCTAssertTrue(model.arrangedBooks().isEmpty)
    }
}
#endif
