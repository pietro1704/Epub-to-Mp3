import AppIntents
import Foundation
import XCTest
@testable import EpubToMp3

@available(iOS 16, macOS 13, *)
@MainActor
final class AppIntentLibraryScopeTests: XCTestCase {
    private let libraryKey = "library.books.v1"
    private let pendingKey = "intent.pendingBookId"

    func testResumeReadsSharedOnlyLibraryAndWritesPendingIdentityToStandardDomain() async throws {
        let shared = try makeDefaults()
        let standard = try makeDefaults()
        try store([
            book(id: "older", title: "Older", openedAt: 10),
            book(id: "recent", title: "Recent", openedAt: 20),
            book(id: "unopened", title: "Unopened", openedAt: nil),
        ], in: shared)

        _ = try await ResumeReadingIntent().perform(sharedDefaults: shared, standardDefaults: standard)

        XCTAssertEqual(standard.string(forKey: pendingKey), "recent")
        XCTAssertNil(shared.object(forKey: pendingKey))
        XCTAssertNil(standard.object(forKey: libraryKey), "Reading the shared library must not copy its catalog.")
    }

    func testOpenBookPrefersSharedIdentityOverConflictingStandardLibrary() async throws {
        let shared = try makeDefaults()
        let standard = try makeDefaults()
        try store([book(id: "shared-book", title: "Shared Title", openedAt: 10)], in: shared)
        try store([book(id: "stale-book", title: "Shared Title", openedAt: 30)], in: standard)
        let originalShared = shared.data(forKey: libraryKey)
        let originalStandard = standard.data(forKey: libraryKey)

        _ = try await openBook("shared title").perform(sharedDefaults: shared, standardDefaults: standard)

        XCTAssertEqual(standard.string(forKey: pendingKey), "shared-book")
        XCTAssertNil(shared.object(forKey: pendingKey))
        XCTAssertEqual(shared.data(forKey: libraryKey), originalShared)
        XCTAssertEqual(standard.data(forKey: libraryKey), originalStandard)
    }

    func testResumeDoesNotChooseNewerBookFromConflictingStandardLibrary() async throws {
        let shared = try makeDefaults()
        let standard = try makeDefaults()
        try store([book(id: "shared-book", title: "Shared", openedAt: 10)], in: shared)
        try store([book(id: "stale-book", title: "Stale", openedAt: 30)], in: standard)

        _ = try await ResumeReadingIntent().perform(sharedDefaults: shared, standardDefaults: standard)

        XCTAssertEqual(standard.string(forKey: pendingKey), "shared-book")
    }

    func testBothIntentsUseStandardLibraryWhenSharedSuiteIsUnavailable() async throws {
        let standard = try makeDefaults()
        try store([book(id: "standard-book", title: "Local Title", openedAt: 10)], in: standard)

        _ = try await ResumeReadingIntent().perform(sharedDefaults: nil, standardDefaults: standard)
        XCTAssertEqual(standard.string(forKey: pendingKey), "standard-book")
        standard.removeObject(forKey: pendingKey)
        _ = try await openBook("Local Title").perform(sharedDefaults: nil, standardDefaults: standard)
        XCTAssertEqual(standard.string(forKey: pendingKey), "standard-book")
    }

    func testMissingOrEmptySharedLibraryDoesNotReviveStandardBooks() async throws {
        let shared = try makeDefaults()
        let standard = try makeDefaults()
        try store([book(id: "stale-book", title: "Stale Title", openedAt: 30)], in: standard)

        try await assertBothIntentsReject(shared: shared, standard: standard, title: "Stale Title")
        try store([], in: shared)
        try await assertBothIntentsReject(shared: shared, standard: standard, title: "Stale Title")
    }

    func testRemovedSharedBookCannotBeSelectedFromStaleStandardLibrary() async throws {
        let shared = try makeDefaults()
        let standard = try makeDefaults()
        let selected = book(id: "removed-book", title: "Removed Title", openedAt: 10)
        try store([selected], in: shared)
        try store([selected], in: standard)
        _ = try await openBook("Removed Title").perform(sharedDefaults: shared, standardDefaults: standard)
        XCTAssertEqual(standard.string(forKey: pendingKey), "removed-book")

        try store([], in: shared)
        try await assertBothIntentsReject(shared: shared, standard: standard, title: "Removed Title")
    }

    func testMalformedSharedLibraryFailsWithoutReadingStandardCatalogOrChangingPendingCommand() async throws {
        let shared = try makeDefaults()
        let standard = try makeDefaults()
        shared.set(Data("invalid catalog".utf8), forKey: libraryKey)
        try store([book(id: "stale-book", title: "Stale Title", openedAt: 30)], in: standard)

        try await assertBothIntentsReject(shared: shared, standard: standard, title: "Stale Title")
    }

    private func assertBothIntentsReject(
        shared: UserDefaults, standard: UserDefaults, title: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        standard.set("existing-command", forKey: pendingKey)
        do {
            _ = try await ResumeReadingIntent().perform(sharedDefaults: shared, standardDefaults: standard)
            XCTFail("Resume must reject a shared library without readable entries.", file: file, line: line)
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line)
        }
        XCTAssertEqual(standard.string(forKey: pendingKey), "existing-command", file: file, line: line)
        do {
            _ = try await openBook(title).perform(sharedDefaults: shared, standardDefaults: standard)
            XCTFail("Open must not revive a book from another persistence domain.", file: file, line: line)
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line)
        }
        XCTAssertEqual(standard.string(forKey: pendingKey), "existing-command", file: file, line: line)
        XCTAssertNil(shared.object(forKey: pendingKey), file: file, line: line)
    }

    private func openBook(_ title: String) -> OpenBookIntent {
        var intent = OpenBookIntent()
        intent.bookTitle = title
        return intent
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "AppIntentLibraryScopeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func store(_ books: [BookEntity], in defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(books), forKey: libraryKey)
    }

    private func book(id: String, title: String, openedAt: TimeInterval?) -> BookEntity {
        BookEntity(id: id, title: title, bookmark: Data([1]), displayFilename: "fixture.epub",
                   addedAt: Date(timeIntervalSinceReferenceDate: 0),
                   lastOpenedAt: openedAt.map { Date(timeIntervalSinceReferenceDate: $0) })
    }
}
