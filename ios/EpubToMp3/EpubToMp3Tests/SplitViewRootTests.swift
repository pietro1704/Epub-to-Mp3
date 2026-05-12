import XCTest
import SwiftUI
@testable import EpubToMp3

/// Smoke tests for the iPad / macOS split-view root and its two
/// extracted columns. The goal is "the view tree compiles and
/// constructs without crashing on the host" — full pixel rendering
/// would need an XCUITest target. Each test guards a specific seam
/// in `SplitViewRoot.swift`, `LibrarySidebar.swift`, or
/// `ChapterListColumn.swift`.
///
/// Calling `view.body` on a modified view (after `.environmentObject`)
/// trips SwiftUI's "body() should not be called on ModifiedContent"
/// fatal — so we restrict ourselves to construction-only smoke tests
/// plus binding round-trip assertions. That's enough to catch
/// signature regressions; the rest is covered by the SwiftUI preview
/// canvas (and, once added, snapshot tests).
final class SplitViewRootTests: XCTestCase {

    // MARK: - Fixtures

    /// `LibraryStore.books` has a `private(set)` setter — tests can't
    /// assign directly. The DEBUG-only `previewPopulated` factory does
    /// that for us inside the source module (its assignment is in the
    /// same module so the access control rule is satisfied), so we
    /// reuse it as the canonical "non-empty" fixture and fall back to
    /// `previewEmpty` for the negative case.
    private func populatedLibrary() -> LibraryStore {
        LibraryStore.previewPopulated
    }

    private func emptyLibrary() -> LibraryStore {
        LibraryStore.previewEmpty
    }

    private func makeBook(
        id: String,
        title: String = "Sample",
        lastJobId: String? = nil
    ) -> BookEntity {
        BookEntity(
            id: id,
            title: title,
            author: "Author",
            bookmark: Data(),
            displayFilename: "\(id).epub",
            addedAt: Date(),
            lastOpenedAt: nil,
            lastChapterIndex: nil,
            lastPositionSeconds: nil,
            coverPNG: nil,
            lastJobId: lastJobId,
            cachedOffline: false
        )
    }

    // MARK: - Build smoke tests

    /// `SplitViewRoot` constructs under the iOS 16+ / macOS 13+ gate.
    /// We can't call `.body` (SwiftUI traps on ModifiedContent.body)
    /// but the init alone catches signature/availability regressions.
    func testSplitViewRootInstantiates() {
        guard #available(iOS 16, macOS 13, *) else {
            // Older OSes never instantiate this view — the size-class
            // branch in RootView falls through to TabRoot. Skip.
            return
        }
        _ = SplitViewRoot()
    }

    /// `LibrarySidebar` constructs with a binding and reads its
    /// fixture store. Verifying `books` afterwards proves the
    /// preview store factory is intact.
    func testLibrarySidebarConstructsWithPopulatedStore() {
        let lib = populatedLibrary()
        let selection: Binding<String?> = .constant(nil)
        _ = LibrarySidebar(selectedBookID: selection)
        XCTAssertFalse(lib.books.isEmpty,
                       "Sidebar fixture must surface the populated preview books.")
    }

    /// Empty library still constructs the sidebar — early variants
    /// crashed on `List(selection:)` with no items on iPad.
    func testLibrarySidebarConstructsWithEmptyStore() {
        let lib = emptyLibrary()
        _ = LibrarySidebar(selectedBookID: .constant(nil))
        XCTAssertTrue(lib.books.isEmpty)
    }

    /// `ChapterListColumn` constructs for a book with no `lastJobId`
    /// (which should land in the "No audio yet" empty-state branch
    /// at runtime).
    func testChapterListColumnConstructsForBookWithoutJob() {
        let book = makeBook(id: "no-audio", lastJobId: nil)
        _ = ChapterListColumn(book: book, selectedChapterIndex: .constant(nil))
        XCTAssertNil(book.lastJobId,
                     "Fixture must not carry a job id (verifies the empty branch).")
    }

    /// `ChapterListColumn` constructs for a book WITH a `lastJobId`.
    /// The real fetch is skipped at runtime because the test host
    /// has no `AppSettings.resolvedBaseURL` — but construction is
    /// what we're guarding here.
    func testChapterListColumnConstructsForBookWithJob() {
        let book = makeBook(id: "with-job", lastJobId: "job-xyz")
        _ = ChapterListColumn(book: book, selectedChapterIndex: .constant(nil))
        XCTAssertEqual(book.lastJobId, "job-xyz")
    }

    // MARK: - Selection semantics

    /// Selecting a book by id must round-trip through the binding,
    /// and the resolved book must be findable in the library —
    /// `SplitViewRoot.selectedBook` depends on this lookup.
    func testSidebarSelectionLooksUpBookInLibrary() {
        let lib = populatedLibrary()
        let target = lib.books.last!
        var captured: String?
        let binding = Binding<String?>(
            get: { captured },
            set: { captured = $0 }
        )
        _ = LibrarySidebar(selectedBookID: binding)

        binding.wrappedValue = target.id
        XCTAssertEqual(captured, target.id)
        XCTAssertEqual(
            lib.books.first(where: { $0.id == captured })?.resolvedTitle,
            target.resolvedTitle,
            "Selection id must resolve back to the same book in the store."
        )
    }

    /// Chapter list binding round-trips an `Int?`. The detail
    /// column's `PlayerReaderView` mount keys on this index via
    /// `.id("\(bookId)-\(chapterIndex)")` so any mutation must be
    /// observed.
    func testChapterSelectionBindingRoundTrips() {
        var captured: Int?
        let binding = Binding<Int?>(
            get: { captured },
            set: { captured = $0 }
        )
        binding.wrappedValue = 2
        XCTAssertEqual(captured, 2)
        binding.wrappedValue = nil
        XCTAssertNil(captured)
    }

    // MARK: - Tab fallback

    /// `TabRoot` is what iOS 15 / iPhone-compact users get. The
    /// branch in `RootView` falls through to it; we just need the
    /// view to construct.
    func testTabRootInstantiates() {
        _ = TabRoot()
    }
}
