import AVFoundation
import XCTest
@testable import EpubToMp3

/// Unit tests for the pure ordering/filtering model that backs the UIKit
/// library collection view. These guard the behavior parity with the
/// former inline `LibraryView.sorted` logic.
final class LibraryGridModelTests: XCTestCase {

    private func make(
        id: String,
        title: String,
        author: String? = nil,
        tags: [String] = [],
        addedAt: Date,
        lastOpenedAt: Date? = nil
    ) -> BookEntity {
        var book = BookEntity(
            id: id,
            title: title,
            author: author,
            bookmark: Data(),
            displayFilename: "\(id).epub",
            addedAt: addedAt,
            lastOpenedAt: lastOpenedAt,
            lastChapterIndex: nil,
            lastPositionSeconds: nil,
            coverPNG: nil,
            lastJobId: nil,
            cachedOffline: false
        )
        book.tags = tags
        return book
    }

    private func date(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

    func testExplicitSortSurvivesReopeningTheLibrary() throws {
        let suite = "library.sort.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(LibraryGridModel.SortMode.saved(in: defaults), .lastPlayed)
        LibraryGridModel.SortMode.title.save(in: defaults)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(LibraryGridModel.SortMode.saved(in: reopened), .title)
        reopened.set("unknown-mode", forKey: "library.sortMode.v1")
        XCTAssertEqual(LibraryGridModel.SortMode.saved(in: reopened), .lastPlayed)
    }

    func testDefaultSortPutsRecentlyPlayedBooksBeforeBooksOnlyOpenedOrAdded() throws {
        var earlier = make(id: "earlier", title: "Earlier", addedAt: date(100), lastOpenedAt: date(800))
        earlier.lastPlayedAt = date(300)
        var recent = make(id: "recent", title: "Recent", addedAt: date(200))
        recent.lastPlayedAt = date(400)
        let unopened = make(id: "new", title: "New", addedAt: date(900))
        let readOnly = make(id: "read", title: "Read", addedAt: date(500), lastOpenedAt: date(950))
        let decoded = try JSONDecoder().decode([BookEntity].self,
            from: JSONEncoder().encode([earlier, unopened, recent, readOnly]))
        XCTAssertEqual(LibraryGridModel(books: decoded).arrangedBooks().map(\.id),
                       ["recent", "earlier", "new", "read"])
        XCTAssertNil(decoded[1].lastPlayedAt)
    }

    @MainActor
    func testOnlyConfirmedOutputRecordsPlaybackForItsBook() throws {
        let suite = "library-recency-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var book = make(id: "played", title: "Played", addedAt: date(100))
        book.bookmark = Data([1])
        book.lastJobId = "embedded-other" // A stale index entry cannot reassign another book’s audio.
        defaults.set(try JSONEncoder().encode([book]), forKey: "library.books.v1")
        defaults.set(book.id, forKey: AudioPlayer.currentBookIDDefaultsKey)
        let library = LibraryStore(defaults: defaults)
        XCTAssertEqual(library.books.map(\.id), [book.id])
        let app = EpubToMp3App(library: library, sessionDefaults: defaults)
        let item = NSObject()
        let output = app.player.playbackClock.audioOutput
        func sample(_ seconds: Double, isOutputting: Bool = true) {
            output.sample(item: ObjectIdentifier(item), seconds: seconds, isOutputting: isOutputting,
                          position: .init(chapterIndex: 0, seconds: seconds, duration: 60,
                                          sentenceID: nil, itemSeconds: seconds, itemDuration: 60))
        }
        let foreign = try JSONDecoder().decode(JobSnapshot.self,
            from: Data(#"{"jobId":"embedded-other","state":"finished"}"#.utf8))
        app.player.setSnapshot(foreign)
        output.didMountQueue(for: foreign.jobId)
        sample(1)
        sample(2)
        XCTAssertNil(library.books.first?.lastPlayedAt)
        output.clear()
        let own = try JSONDecoder().decode(JobSnapshot.self,
            from: Data(#"{"jobId":"embedded-played","state":"finished"}"#.utf8))
        // A job from a manual conversion may resume while this reader is open.
        let manual = try JSONDecoder().decode(JobSnapshot.self,
            from: Data(#"{"jobId":"manual-job","state":"finished"}"#.utf8))
        output.bindReaderJob("reader-job", to: book.id)
        app.player.setSnapshot(manual)
        output.didMountQueue(for: manual.jobId)
        sample(1)
        sample(2)
        XCTAssertNil(library.books.first?.lastPlayedAt)

        // Switching the UI projection cannot relabel the previous queue.
        app.player.setSnapshot(own)
        sample(3)
        sample(4)
        XCTAssertNil(library.books.first?.lastPlayedAt)
        output.didMountQueue(for: own.jobId)
        sample(1, isOutputting: false)
        sample(2, isOutputting: false)
        XCTAssertNil(library.books.first?.lastPlayedAt)
        sample(1)
        XCTAssertNil(library.books.first?.lastPlayedAt)
        sample(2)
        let playedAt = try XCTUnwrap(library.books.first?.lastPlayedAt)
        sample(3)
        XCTAssertEqual(library.books.first?.lastPlayedAt, playedAt)
        book.title = "Edited after playback"
        library.update(book)
        XCTAssertEqual(library.books.first?.title, book.title)
        try library.flushPersistenceSync()
        XCTAssertEqual(LibraryStore(defaults: defaults).books.first?.lastPlayedAt, playedAt)
    }

    @MainActor
    func testEndingSpeechDoesNotRecordAnOlderAudioSampleAgain() async throws {
        let suite = "library-recency-output-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var audioBook = make(id: "audio", title: "Audio", addedAt: date(100))
        var speechBook = make(id: "speech", title: "Speech", addedAt: date(200))
        audioBook.bookmark = Data([1])
        speechBook.bookmark = Data([2])
        defaults.set(try JSONEncoder().encode([audioBook, speechBook]), forKey: "library.books.v1")

        let library = LibraryStore(defaults: defaults)
        let synth = SpeechFallbackPlayerTests.FakeSynthesizer()
        let speech = SpeechFallbackPlayer(synthesizer: synth,
            sessionConfigurator: SpeechFallbackPlayerTests.FakeSpeechAudioSession())
        let player = AudioPlayer(
            resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)),
            speechFallback: speech)
        let app = EpubToMp3App(library: library, sessionDefaults: defaults, player: player)
        defer { withExtendedLifetime(app) { } }

        let output = player.playbackClock.audioOutput
        output.didMountQueue(for: "embedded-audio")
        let item = NSObject()
        for seconds in [1.0, 2.0] {
            output.sample(item: ObjectIdentifier(item), seconds: seconds, isOutputting: true,
                position: .init(chapterIndex: 0, seconds: seconds, duration: 60,
                                sentenceID: nil, itemSeconds: seconds, itemDuration: 60))
        }
        let audioDate = try XCTUnwrap(library.books.first { $0.id == audioBook.id }?.lastPlayedAt)

        speech.speak(text: "Speech", bookID: speechBook.id)
        let utterance = try XCTUnwrap(synth.spoken.first)
        speech.speechSynthesizer(AVSpeechSynthesizer(),
            willSpeakRangeOfSpeechString: NSRange(location: 0, length: 6), utterance: utterance)
        for _ in 0..<25 {
            if speech.spokenWord != nil { break }
            try await Task.sleep(nanoseconds: 4_000_000)
        }
        XCTAssertNotNil(library.books.first { $0.id == speechBook.id }?.lastPlayedAt)
        XCTAssertEqual(output.position?.bookID, audioBook.id)

        speech.stop()
        XCTAssertEqual(library.books.first { $0.id == audioBook.id }?.lastPlayedAt, audioDate)
        XCTAssertEqual(LibraryGridModel(books: library.books).arrangedBooks().first?.id, speechBook.id)
        try library.flushPersistenceSync()
    }

#if os(macOS)
    @MainActor
    func testMacReaderPlaybackRecordsItsBookWithoutAnyPlayingBookSaved() async throws {
        let suite = "library-mac-recency-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let library = LibraryStore(defaults: defaults, importDirectory: directory)
        let source = try EpubFixture.createWithChapters(["The book that will play."])
        let otherSource = try EpubFixture.createWithChapters(["A different book that will stay silent."])
        defer {
            defaults.removePersistentDomain(forName: suite)
            for url in [source, otherSource, directory] { try? FileManager.default.removeItem(at: url) }
        }
        let book = try library.importBook(from: source)
        let other = try library.importBook(from: otherSource)
        XCTAssertNotEqual(book.id, other.id)
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey, AudioPlayer.currentBookIDDefaultsKey,
                    AudioPlayer.currentChapterIndexDefaultsKey, AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey, AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let previous = keys.map { standard.object(forKey: $0) }
        let widget = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        func isNowPlayingKey(_ key: String) -> Bool {
            key == "currentlyPlayingBookId" || key.hasPrefix("widget.nowPlaying")
        }
        let widgetValues = widget?.dictionaryRepresentation().filter { isNowPlayingKey($0.key) } ?? [:]
        let app = EpubToMp3App(library: library)
        let submitted = expectation(description: "Mac reader playback hands off its source-bound job")
        let replacementSubmitted = expectation(description: "Replacement reader playback hands off its job")
        let retiredResultReturned = expectation(description: "Retired conversion returns its result")
        let completion = AsyncStream<Void>.makeStream()
        let replacementCompletion = AsyncStream<Void>.makeStream()
        var retiringControl: ConverterPlaybackControl?
        let session = MacReaderPlaybackSession(settings: AppSettings(defaults: defaults), library: library,
            player: app.player, playerPresentation: PlayerPresentation(defaults: defaults),
            conversionExecutor: { _, jobID, _, _, control, _, _, _, _ in
                XCTAssertEqual(app.player.snapshot?.jobId, jobID)
                if retiringControl != nil {
                    replacementSubmitted.fulfill()
                    for await _ in replacementCompletion.stream { }
                    throw CancellationError()
                }
                retiringControl = control
                submitted.fulfill()
                for await _ in completion.stream { }
                let manifest = try JSONSerialization.data(withJSONObject: ["manifest": [
                    "jobId": jobID, "title": book.resolvedTitle, "author": book.author ?? "", "chapters": []
                ]])
                retiredResultReturned.fulfill()
                return .init(jobID: jobID, manifestJSON: manifest, outputDirectory: directory)
            })
        defer {
            session.cancel()
            completion.continuation.finish()
            replacementCompletion.continuation.finish()
            for (key, value) in zip(keys, previous) { standard.set(value, forKey: key) }
            if let widget {
                for key in widget.dictionaryRepresentation().keys where isNowPlayingKey(key) {
                    widget.removeObject(forKey: key)
                }
                for (key, value) in widgetValues { widget.set(value, forKey: key) }
            }
        }
        ReaderSessionState.setCurrentlyReading(bookID: book.id)
        standard.set(0, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        standard.removeObject(forKey: AudioPlayer.currentBookIDDefaultsKey)
        XCTAssertNil(standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey))
        session.start(owner: self)
        await fulfillment(of: [submitted], timeout: 5)
        XCTAssertNil(library.books.first { $0.id == book.id }?.lastPlayedAt)

        // The reader can move elsewhere between mount and confirmed output.
        let installed = try XCTUnwrap(app.player.snapshot)
        app.player.playbackClock.audioOutput.didMountQueue(for: installed.jobId)
        standard.set(other.id, forKey: AudioPlayer.currentBookIDDefaultsKey)
        let item = NSObject()
        for seconds in [1.0, 2.0] {
            app.player.playbackClock.audioOutput.sample(item: ObjectIdentifier(item), seconds: seconds, isOutputting: true,
                position: .init(chapterIndex: 0, seconds: seconds, duration: 60,
                                sentenceID: nil, itemSeconds: seconds, itemDuration: 60))
        }

        let playedAt = try XCTUnwrap(library.books.first { $0.id == book.id }?.lastPlayedAt)
        XCTAssertNil(library.books.first { $0.id == other.id }?.lastPlayedAt)
        XCTAssertEqual(LibraryGridModel(books: library.books).arrangedBooks().first?.id, book.id)

        ReaderSessionState.setCurrentlyReading(bookID: other.id)
        session.start(owner: self)
        await fulfillment(of: [replacementSubmitted], timeout: 5)
        let replacement = try XCTUnwrap(app.player.snapshot)
        XCTAssertNotEqual(replacement.jobId, installed.jobId)
        XCTAssertTrue(try XCTUnwrap(retiringControl).isCancellationRequested)

        completion.continuation.finish()
        await fulfillment(of: [retiredResultReturned], timeout: 5)
        XCTAssertEqual(app.player.snapshot, replacement)
        XCTAssertNil(library.books.first { $0.id == book.id }?.lastJobId)
        XCTAssertEqual(library.books.first { $0.id == book.id }?.lastPlayedAt, playedAt)
        XCTAssertNil(library.books.first { $0.id == other.id }?.lastPlayedAt)
    }
#endif

    func testSortLastOpenedFallsBackToAddedAt() {
        let a = make(id: "a", title: "A", addedAt: date(100), lastOpenedAt: date(500))
        let b = make(id: "b", title: "B", addedAt: date(900), lastOpenedAt: nil)
        let c = make(id: "c", title: "C", addedAt: date(200), lastOpenedAt: date(300))
        let model = LibraryGridModel(books: [a, b, c], sortMode: .lastOpened)
        // b uses addedAt=900 (no lastOpened) → first; a=500; c=300.
        XCTAssertEqual(model.arrangedBooks().map(\.id), ["b", "a", "c"])
    }

    func testSortTitleIsLocalizedAscending() {
        let a = make(id: "a", title: "Zebra", addedAt: date(1))
        let b = make(id: "b", title: "apple", addedAt: date(1))
        let c = make(id: "c", title: "Éclair", addedAt: date(1))
        let model = LibraryGridModel(books: [a, b, c], sortMode: .title)
        XCTAssertEqual(model.arrangedBooks().map(\.id), ["b", "c", "a"])
    }

    func testSortAddedDateNewestFirst() {
        let a = make(id: "a", title: "A", addedAt: date(100))
        let b = make(id: "b", title: "B", addedAt: date(300))
        let c = make(id: "c", title: "C", addedAt: date(200))
        let model = LibraryGridModel(books: [a, b, c], sortMode: .addedDate)
        XCTAssertEqual(model.arrangedBooks().map(\.id), ["b", "c", "a"])
    }

    func testSearchMatchesTitleAuthorAndTagsCaseInsensitively() {
        let byTitle = make(id: "t", title: "The FOUNDATION", addedAt: date(3))
        let byAuthor = make(id: "au", title: "Other", author: "Isaac ASIMOV", addedAt: date(2))
        let byTag = make(id: "tg", title: "Nope", tags: ["Sci-Fi"], addedAt: date(1))
        let miss = make(id: "m", title: "Cooking", addedAt: date(4))
        let model = LibraryGridModel(
            books: [byTitle, byAuthor, byTag, miss],
            searchQuery: "  foun ",
            sortMode: .addedDate
        )
        XCTAssertEqual(model.arrangedBooks().map(\.id), ["t"])

        let tagModel = LibraryGridModel(books: [byTitle, byAuthor, byTag, miss], searchQuery: "sci-fi")
        XCTAssertEqual(tagModel.arrangedBooks().map(\.id), ["tg"])
    }

    func testTagFilterRestrictsToTaggedBooks() {
        let tagged = make(id: "x", title: "X", tags: ["fav"], addedAt: date(2))
        let untagged = make(id: "y", title: "Y", addedAt: date(1))
        let model = LibraryGridModel(books: [tagged, untagged], selectedTag: "fav", sortMode: .addedDate)
        XCTAssertEqual(model.arrangedBooks().map(\.id), ["x"])
    }

    func testEmptyQueryReturnsAll() {
        let a = make(id: "a", title: "A", addedAt: date(2))
        let b = make(id: "b", title: "B", addedAt: date(1))
        let model = LibraryGridModel(books: [a, b], searchQuery: "   ", sortMode: .addedDate)
        XCTAssertEqual(model.arrangedBooks().map(\.id).count, 2)
    }

    // MARK: - Layout metrics (shared by SwiftUI + UIKit renderers)

    func testColumnCountKeepsTwoAcrossWidths() {
        let m = LibraryGridLayoutMetrics()
        XCTAssertEqual(m.columnCount(forWidth: 400), 2)
        XCTAssertEqual(m.columnCount(forWidth: 800), 2)
    }

    func testTileWidthsFillTheRequestedColumns() {
        let m = LibraryGridLayoutMetrics()
        XCTAssertEqual(m.tileWidth(forWidth: 1200, columns: 2), 570, accuracy: 0.5)
        // 4 columns in 800pt → ~175pt, unclamped.
        XCTAssertEqual(m.tileWidth(forWidth: 800, columns: 4), 175, accuracy: 0.5)
    }
}
