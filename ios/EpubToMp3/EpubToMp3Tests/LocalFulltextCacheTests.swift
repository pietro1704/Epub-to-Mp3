import XCTest
@testable import EpubToMp3

/// Tests for the durable `EbookFulltext` binary cache and legacy JSON migration. The cache is a
/// thin Swift wrapper around Application Support reader payloads
/// and is intentionally NOT replaced by `python_app.src.cache_manager`
/// — that module manages the conversion pipeline's parsed-text
/// checkpoints (different lifecycle, different keying, lives under
/// `PERSISTENT_ROOT/.cache/`).
final class LocalFulltextCacheTests: XCTestCase {

    private func uniqueId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private func completePayload(_ id: String) -> EbookFulltext {
        EbookFulltext(jobId: id, bookTitle: "Book", bookAuthor: "Author", chapters: [
            .init(index: 1, name: "Chapter", sourcePath: "text/chapter.xhtml", text: "Reader text",
                  speechText: "Speech text", html: "<p><b>Reader</b> text</p>", css: "p {color:red}",
                  charCount: 11, segments: [.init(id: "sentence", text: "Reader text", startMs: 0, endMs: 100)],
                  resources: [.init(href: "image.png", mediaType: "image/png", dataBase64: "AA==")],
                  footnotes: [.init(number: "1", text: "Note")], contentKind: "text")
        ])
    }

    private func canonicalJSON(_ payload: EbookFulltext) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    func testBinaryDiskRoundTripPreservesFullCanonicalJSON() throws {
        let id = uniqueId()
        defer { LocalFulltextCache.evict(bookId: id) }
        let payload = completePayload(id)
        LocalFulltextCache.save(payload, bookId: id)
        let url = try XCTUnwrap(LocalFulltextCache.storageURL(bookId: id))
        XCTAssertEqual(url.pathExtension, "plist")
        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data.prefix(8), encoding: .utf8), "bplist00")
        let disk = try PropertyListDecoder().decode(EbookFulltext.self, from: data)
        XCTAssertEqual(try canonicalJSON(disk), try canonicalJSON(payload))
    }

    func testLegacyDurableJSONMigratesWithoutChangingOldBytes() throws {
        try assertDurableMigration(corruptPrimary: false)
    }

    func testCorruptPrimaryFallsBackToValidDurableJSON() throws {
        try assertDurableMigration(corruptPrimary: true)
    }

    private func assertDurableMigration(corruptPrimary: Bool) throws {
        let id = uniqueId()
        defer { LocalFulltextCache.evict(bookId: id) }
        let primary = try XCTUnwrap(LocalFulltextCache.storageURL(bookId: id))
        let legacy = primary.deletingPathExtension().appendingPathExtension("json")
        let original = try canonicalJSON(completePayload(id))
        try original.write(to: legacy)
        if corruptPrimary { try Data("Corrupt primary".utf8).write(to: primary) }
        let restored = try XCTUnwrap(LocalFulltextCache.read(bookId: id))
        XCTAssertEqual(try canonicalJSON(restored), original)
        XCTAssertEqual(try Data(contentsOf: legacy), original)
        let migrated = try PropertyListDecoder().decode(EbookFulltext.self, from: Data(contentsOf: primary))
        XCTAssertEqual(try canonicalJSON(migrated), original)
    }

    func testLegacyCachesJSONMigratesAndEvictRemovesOnlyRequestedFormats() throws {
        let id = uniqueId()
        defer { LocalFulltextCache.evict(bookId: id) }
        let primary = try XCTUnwrap(LocalFulltextCache.storageURL(bookId: id))
        let durableJSON = primary.deletingPathExtension().appendingPathExtension("json")
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
            .appendingPathComponent("fulltext-v5", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let legacy = caches.appendingPathComponent("\(id).json")
        let original = try canonicalJSON(completePayload(id))
        try original.write(to: legacy)
        XCTAssertEqual(LocalFulltextCache.read(bookId: id), completePayload(id))
        XCTAssertEqual(try Data(contentsOf: legacy), original)
        XCTAssertEqual(try PropertyListDecoder().decode(EbookFulltext.self, from: Data(contentsOf: primary)), completePayload(id))
        try original.write(to: durableJSON)
        let otherID = uniqueId()
        defer { LocalFulltextCache.evict(bookId: otherID) }
        let other = try XCTUnwrap(LocalFulltextCache.storageURL(bookId: otherID))
        try original.write(to: other)
        LocalFulltextCache.evict(bookId: id)
        for url in [primary, durableJSON, legacy] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertNil(LocalFulltextCache.inMemoryPayload(bookId: id))
        XCTAssertEqual(try Data(contentsOf: other), original)
    }

    func testCorruptPrimaryAndLegacyAreMissesWithoutRewritingBytes() throws {
        let id = uniqueId()
        defer { LocalFulltextCache.evict(bookId: id) }
        let primary = try XCTUnwrap(LocalFulltextCache.storageURL(bookId: id))
        let legacy = primary.deletingPathExtension().appendingPathExtension("json")
        let corrupt = Data("Invalid payload".utf8)
        try corrupt.write(to: primary)
        try corrupt.write(to: legacy)
        XCTAssertNil(LocalFulltextCache.read(bookId: id))
        XCTAssertEqual(try Data(contentsOf: primary), corrupt)
        XCTAssertEqual(try Data(contentsOf: legacy), corrupt)
    }

    func testMixedFormatBudgetNormalizesPreservedIDsAndRetainsUnrelatedFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixed-fulltext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preserved = directory.appendingPathComponent("keepbook.plist")
        let oldJSON = directory.appendingPathComponent("oldjson.json")
        let oldPlist = directory.appendingPathComponent("oldbinary.plist")
        let unrelated = directory.appendingPathComponent("download.mp3")
        for url in [preserved, oldJSON, oldPlist, unrelated] {
            try Data(repeating: 0xA5, count: 100).write(to: url)
        }
        let removed = LocalFulltextCache.reclaimRebuildablePayloads(
            toMaximumBytes: 100, preservingBookIDs: ["keep-book"], directory: directory)
        XCTAssertEqual(Set(removed), ["oldjson", "oldbinary"])
        XCTAssertEqual(try Data(contentsOf: preserved), Data(repeating: 0xA5, count: 100))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data(repeating: 0xA5, count: 100))
    }

    func testRoundTrip() throws {
        let id = uniqueId()
        defer { LocalFulltextCache.evict(bookId: id) }

        let payload = EbookFulltext(
            jobId: id,
            bookTitle: "Foundation",
            bookAuthor: "Asimov",
            chapters: [
                .init(index: 1, name: "I",
                      text: "Hari Seldon stood watch.",
                      html: nil, css: nil, charCount: 24, segments: nil)
            ]
        )
        LocalFulltextCache.save(payload, bookId: id)
        let read = LocalFulltextCache.read(bookId: id)
        XCTAssertEqual(read?.bookTitle, "Foundation")
        XCTAssertEqual(read?.chapters.count, 1)
        XCTAssertEqual(read?.chapters.first?.text, "Hari Seldon stood watch.")
    }

    func testReadReturnsNilForUnknownBook() {
        XCTAssertNil(LocalFulltextCache.read(bookId: "no-such-book-\(UUID().uuidString)"))
    }

    func testEvictRemovesEntry() {
        let id = uniqueId()
        let payload = EbookFulltext(jobId: id, bookTitle: nil,
                                    bookAuthor: nil, chapters: [])
        LocalFulltextCache.save(payload, bookId: id)
        XCTAssertNotNil(LocalFulltextCache.read(bookId: id))
        LocalFulltextCache.evict(bookId: id)
        XCTAssertNil(LocalFulltextCache.read(bookId: id))
    }

    func testReaderPayloadUsesDurableApplicationSupportStorage() throws {
        let id = uniqueId()
        defer { LocalFulltextCache.evict(bookId: id) }

        let url = try XCTUnwrap(LocalFulltextCache.storageURL(bookId: id))
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )

        XCTAssertTrue(
            url.standardizedFileURL.path.hasPrefix(applicationSupport.standardizedFileURL.path + "/"),
            "Prepared reader content must survive the OS cache purge."
        )
    }

    func testReclaimsOldRebuildablePayloadsWithoutTouchingThePreservedBook() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rebuildable-fulltext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldest = directory.appendingPathComponent("oldest.json")
        let current = directory.appendingPathComponent("current.json")
        try Data(repeating: 0xA5, count: 100).write(to: oldest)
        try Data(repeating: 0x5A, count: 100).write(to: current)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: oldest.path
        )

        let removed = LocalFulltextCache.reclaimRebuildablePayloads(
            toMaximumBytes: 100,
            preservingBookIDs: ["current"],
            directory: directory
        )

        XCTAssertEqual(removed, ["oldest"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
    }
}
