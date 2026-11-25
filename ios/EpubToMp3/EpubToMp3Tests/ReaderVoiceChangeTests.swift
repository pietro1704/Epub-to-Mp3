import XCTest
#if os(macOS)
import AppKit
#endif
@testable import EpubToMp3

@MainActor
final class ReaderVoiceChangeTests: XCTestCase {
    func testPickerOpeningAndChoosingCurrentVoiceLeaveSelectionUntouched() {
        var changes: [TtsSelection] = []
        let picker = ReaderVoicePicker(selection: .defaultPiper) { changes.append($0) }

        XCTAssertTrue(picker.marks(.defaultPiper))
        XCTAssertFalse(picker.marks(.systemDefault))
        XCTAssertTrue(changes.isEmpty, "Opening or dismissing the picker issues no change")
        picker.choose(.defaultPiper)
        XCTAssertTrue(changes.isEmpty)
        picker.choose(.systemDefault)
        XCTAssertEqual(changes, [.systemDefault])
    }

    func testVoicePickerCannotApplyAfterReaderSwitchesBooks() throws {
        let suite = "stale-voice-picker-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.selectPrimaryNarration(.defaultPiper)
        var current = BookEntity(id: "first", title: "First", bookmark: Data([1]),
            displayFilename: "first.epub", addedAt: Date())
        let request = ReaderVoicePickerRequest(settings: settings, library: LibraryStore(defaults: defaults),
            player: AudioPlayer(), currentContext: { .init(book: current) },
            restart: { _, _ in XCTFail("A retired picker cannot restart playback") })
        let picker = try XCTUnwrap(request.picker())
        current = BookEntity(id: "second", title: "Second", bookmark: Data([1]),
            displayFilename: "second.epub", addedAt: Date())

        picker.choose(.systemDefault)

        XCTAssertEqual(settings.primaryTtsSelection, .defaultPiper)
    }

    func testTextAnchorCountsScalarOffsetsAcrossEmojiAndCombiningMarks() throws {
        let prefix = "👩🏽‍🚀 A\u{301} primeira.\n  "
        let text = prefix + "Segunda frase."
        let chapter = NativeReaderTestHarness.chapter(text)
        let sentence = try XCTUnwrap(chapter.splitSentences().last)
        let ratio = try XCTUnwrap(ReaderVoiceChange.textAnchor(in: chapter, position: nil,
            activeSentence: sentence.id))
        XCTAssertNotEqual(prefix.count, prefix.unicodeScalars.count)
        XCTAssertEqual(ratio, Double(prefix.unicodeScalars.count) / Double(text.unicodeScalars.count), accuracy: 0.000001)
    }

    func testResolvedSystemFallbackMarksRepresentedVoiceInsteadOfConfiguredPiper() throws {
        let player = AudioPlayer()
        defer { player.stop() }
        let book = BookEntity(id: "voice-fallback", title: "Book", bookmark: Data([1]),
            displayFilename: "book.epub", addedAt: Date())
        let snapshot = try JSONDecoder().decode(JobSnapshot.self,
            from: Data(#"{"jobId":"fallback","state":"running","engine":"system","voice":"Luciana (installed.luciana)"}"#.utf8))
        player.play(snapshot: snapshot, restoreAutoplay: false)
        let active = ReaderVoiceChange.selection(player: player, book: book, ownedJobID: snapshot.jobId,
            requested: nil, configured: .defaultPiper)
        let picker = ReaderVoicePicker(selection: active) { _ in XCTFail("The active voice must not restart") }
        let represented = TtsSelection(engine: "system", modelID: "fixture-system", voice: "installed.luciana")
        XCTAssertTrue(picker.marks(represented))
        XCTAssertFalse(picker.marks(.defaultPiper))
        picker.choose(represented)
    }

    func testComicCanChoosePreferenceWithoutProducingAListeningRequest() {
        let player = AudioPlayer()
        let comic = BookEntity(id: "comic", title: "Comic", bookmark: Data([1]),
            displayFilename: "comic.cbz", addedAt: Date(), fileType: .cbz)
        let starting = ReaderVoiceChange(chapter: 1, pageRatio: 0.5, seek: nil, autoplay: true)
        var selected: TtsSelection?
        let picker = ReaderVoicePicker(selection: .defaultPiper) { selected = $0 }

        picker.choose(.systemDefault)

        XCTAssertEqual(selected, .systemDefault)
        XCTAssertNil(ReaderVoiceChange.capture(player: player, book: comic, starting: starting, ownedJobID: nil))
        XCTAssertNil(player.snapshot)
    }

    func testVoiceChangeUsesCurrentJobPendingChapterTimeAndPreservesPause() throws {
        let player = AudioPlayer()
        defer { player.stop() }
        let book = BookEntity(id: "voice-book", title: "Voice book", bookmark: Data([1]),
            displayFilename: "book.epub", addedAt: Date())
        let snapshot = JobSnapshot(jobId: "old-voice", state: "running", bookTitle: book.title,
            bookAuthor: nil, coverUrl: nil, coverMimeType: nil, engine: "piper",
            voice: TtsSelection.defaultPiperModelID, language: "pt-BR", progressPercent: 0,
            chaptersTotal: nil, chaptersCompleted: 0, chapterProgress: [], outputs: nil,
            logUrl: nil, error: nil, lastActivityAt: nil, chapterIndexBase: 0)
        player.play(snapshot: snapshot, restoreAutoplay: false)
        player.isConverting = true
        let pending = PendingPlaybackSeek.ChapterRequest(id: UUID(), jobID: snapshot.jobId,
            chapterIndex: 7, autoplay: false, position: 24)
        player.restoreListeningSeek(pending, jobID: snapshot.jobId)

        XCTAssertNil(ReaderVoiceChange.capture(player: player, book: book, starting: nil, ownedJobID: "retired"))
        XCTAssertEqual(ReaderVoiceChange.selection(player: player, book: book, ownedJobID: snapshot.jobId,
            requested: .systemDefault, configured: .systemDefault), .defaultPiper)
        let target = try XCTUnwrap(ReaderVoiceChange.capture(player: player, book: book, starting: nil,
            ownedJobID: snapshot.jobId))
        XCTAssertEqual(target.chapter, 7)
        XCTAssertEqual(target.seek?.position, 24)
        XCTAssertNil(target.pageRatio)
        XCTAssertFalse(target.autoplay)
    }
#if os(macOS)
    private final class ListeningPositions { var requests: [[String: Int]] = [] }

    func testMacPDFVoiceChangeKeepsExactOffsetAndChapterTimeAndRejectsRetiredJob() async throws {
        let suite = "mac-voice-change-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let selectedText = "Earlier words. Selected PDF passage."
        let source = try PdfFixture.createMultiPage(pages: [
            (heading: "Earlier", body: "First chapter."), (heading: "Selected", body: selectedText)
        ])
        let metadata = try JSONSerialization.data(withJSONObject: ["chapters": [
            ["index": "1", "name": "Earlier", "sourcePath": "page-1", "text": "First chapter."],
            ["index": "2", "name": "Selected", "sourcePath": "page-2", "text": selectedText],
        ]])
        let map = try PDFReadingAudioMap(metadata: metadata, pageTexts: ["First chapter.", selectedText])
        let selectedWord = try XCTUnwrap(selectedText.range(of: "Selected"))
        let anchor = try XCTUnwrap(map.anchor(page: 1, character: selectedWord.lowerBound.utf16Offset(in: selectedText)))
        let library = LibraryStore(defaults: defaults, defaultsKey: "library", importDirectory: root)
        let book = try library.importBook(from: source)
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey, AudioPlayer.currentBookIDDefaultsKey,
                    AudioPlayer.currentChapterIndexDefaultsKey]
        let saved = keys.map { standard.object(forKey: $0) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let settings = AppSettings(defaults: defaults)
        let submitted = [expectation(description: "Old job submitted"), expectation(description: "Voice job submitted")]
        var jobs: [String] = []
        var controls: [ConverterPlaybackControl] = []
        var progress: [(@MainActor @Sendable (RustConversionCoordinator.ConversionProgressEvent) -> Void)?] = []
        var submittedOptions: [ConversionOptions?] = []
        var pending: [CheckedContinuation<RustConversionCoordinator.Result, Error>] = []
        let positions = ListeningPositions()
        let handle = Unmanaged.passUnretained(positions).toOpaque()
        let session = MacReaderPlaybackSession(settings: settings, library: library, player: player,
            playerPresentation: PlayerPresentation(defaults: defaults),
            conversionExecutor: { _, job, start, _, control, options, onProgress, _, _ in
                XCTAssertEqual(start, 1)
                jobs.append(job)
                controls.append(control)
                progress.append(onProgress)
                submittedOptions.append(options)
                return try await withCheckedThrowingContinuation { continuation in
                    pending.append(continuation)
                    submitted[jobs.count - 1].fulfill()
                }
            }, makePlaybackControl: {
                ConverterPlaybackControl(rawHandle: handle,
                    free: { _ in }, cancel: { _ in }, prioritize: { _, _ in true },
                    setWindow: { _, _, _ in }, windowContains: { _, _ in true },
                    listeningPosition: { raw, json in
                        guard let raw, let json,
                              let request = try? JSONDecoder().decode([String: Int].self,
                                  from: Data(String(cString: json).utf8)) else { return false }
                        Unmanaged<ListeningPositions>.fromOpaque(UnsafeMutableRawPointer(mutating: raw))
                            .takeUnretainedValue().requests.append(request)
                        return true
                    })
            })
        defer {
            session.cancel()
            pending.forEach { $0.resume(throwing: CancellationError()) }
            player.stop()
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: suite)
            for url in [root, source] { try? FileManager.default.removeItem(at: url) }
        }
        standard.set(book.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        session.start(owner: self, pdfAnchor: anchor)
        await fulfillment(of: [submitted[0]], timeout: 5)
        let oldJob = try XCTUnwrap(jobs.first)
        let original = try XCTUnwrap(positions.requests.last)
        XCTAssertEqual(original["chapter_index"], 1)
        XCTAssertEqual(original["text_offset"], anchor.sourceScalarOffset)
        XCTAssertGreaterThan(anchor.sourceScalarOffset, 0)
        let prepared = try XCTUnwrap(session.startingVoicePosition)
        let seek = PendingPlaybackSeek.ChapterRequest(id: UUID(), jobID: oldJob,
            chapterIndex: 1, autoplay: false, position: 12)
        var options = ConversionOptions(forceReprocess: true)
        options.ttsPreferences = .init(primary: .systemDefault, secondary: nil, allowOnlineFallback: false)
        session.start(owner: self, optionsOverride: options, chapterOverride: 1, pageRatioOverride: .some(nil),
            voiceChange: .init(chapter: prepared.chapter, pageRatio: nil, seek: seek, autoplay: false,
                sourceScalarOffset: prepared.sourceScalarOffset))
        await fulfillment(of: [submitted[1]], timeout: 5)
        let newJob = try XCTUnwrap(jobs.last)
        XCTAssertNotEqual(oldJob, newJob)
        XCTAssertEqual(positions.requests.last?["chapter_index"], original["chapter_index"])
        XCTAssertEqual(positions.requests.last?["text_offset"], original["text_offset"])
        XCTAssertEqual(controls.first?.isCancellationRequested, true)
        XCTAssertEqual(submittedOptions.last.flatMap { $0 }?.ttsPreferences?.primary, .systemDefault)
        (progress.first ?? nil)?(.init(jobId: oldJob, state: "running", chapterIndex: 1,
            chaptersTotal: 1, chaptersCompleted: 0, percent: 90, engine: "retired", message: "Retired"))
        let navigation = try XCTUnwrap(player.pendingNavigation)
        XCTAssertEqual(navigation.jobID, newJob)
        XCTAssertEqual(navigation.target, .chapterTime(12))
        XCTAssertEqual(player.pendingListeningSeek(for: navigation)?.autoplay, false)
        XCTAssertNotEqual(player.snapshot?.engine, "retired")
    }

    /// When the book's language is unknown the reader lists the general catalog. That list must not offer an online
    /// voice without consent: choosing it would save Edge as the primary voice.
    func testTheCatalogVoiceListOffersNoOnlineVoiceWithoutConsent() {
        let picker = ReaderVoicePicker(selection: .systemDefault, resolvedTitle: nil) { _ in }

        let choices = picker.choices(from: SpeechModelLibraryViewState(snapshot: nil))

        XCTAssertTrue(choices.contains { $0.selection == .systemDefault })
        XCTAssertFalse(choices.contains { $0.selection.isEdge })
    }

    func testMacReaderMoreShowsMarkedVoiceChoicesImmediately() async throws {
        let suite = "mac-reader-voice-picker-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let importDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let source = try EpubFixture.createWithChapters(["A readable chapter."])
        let library = LibraryStore(defaults: defaults, defaultsKey: "library", importDirectory: importDirectory)
        let book = try library.importBook(from: source)
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey, AudioPlayer.currentBookIDDefaultsKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey, AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey, "reader.recentTool.v1"]
        let saved = keys.map { standard.object(forKey: $0) }
        let settings = AppSettings(defaults: defaults)
        settings.selectPrimaryNarration(.systemDefault)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let root = MacAppKitRootController(settings: settings, library: library, player: player,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            playerPresentation: PlayerPresentation(defaults: defaults))
        let window = NSWindow(contentViewController: root)
        defer {
            window.orderOut(nil)
            player.stop()
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: suite)
            for url in [importDirectory, source] { try? FileManager.default.removeItem(at: url) }
        }
        window.setContentSize(NSSize(width: 900, height: 650))
        window.makeKeyAndOrderFront(nil)
        root.showReader(bookID: book.id)
        func moreButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.accessibilityIdentifier() == "reader.more" { return button }
            return view.subviews.lazy.compactMap { moreButton(in: $0) }.first
        }
        let more = try XCTUnwrap(moreButton(in: root.view))
        let command = try XCTUnwrap(more.menu?.items.first { $0.representedObject as? String == "voiceModels" })
        let visible = expectation(description: "The reader voice choices menu begins tracking")
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
            object: nil, queue: .main) { notification in
            MainActor.assumeIsolated {
                guard let menu = notification.object as? NSMenu, menu.title == L10n.string("models.title") else { return }
                // The book's language decides the list: the active system voice stays marked, an online
                // voice is listed only with the online consent, and the Models screen is one item away.
                XCTAssertEqual(menu.items.filter { $0.state == .on }.map(\.title).count, 1)
                XCTAssertTrue([L10n.string("settings.systemTts"), L10n.string("models.systemVoice")]
                    .contains(menu.items.first { $0.state == .on }?.title ?? ""))
                XCTAssertFalse(menu.items.contains { $0.title == "Edge" }, "Online voices need the consent")
                XCTAssertTrue(menu.items.contains { $0.title == L10n.string("models.missing.open") })
                visible.fulfill()
                let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
                    MainActor.assumeIsolated { menu.cancelTracking() }
                }
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(command.action), to: command.target, from: command))
        await fulfillment(of: [visible], timeout: 15)

        XCTAssertEqual(settings.primaryTtsSelection, .systemDefault)
        XCTAssertNil(player.snapshot)
    }

    func testNativeMoreMenuDispatchesVoiceModelsAction() throws {
        let suite = "voice-menu-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var selected: [ReaderTool] = []
        let toolbar = MacReaderToolBar(defaults: defaults) { tool, _ in selected.append(tool) }
        let menu = try XCTUnwrap(toolbar.more.menu)
        let index = try XCTUnwrap(menu.items.firstIndex { $0.representedObject as? String == "voiceModels" })

        menu.performActionForItem(at: index)

        XCTAssertEqual(selected, [.voiceModels])
    }
#endif

    // MARK: reader model switch by language

    private func row(_ id: String, _ title: String, _ availability: ModelsByLanguageViewState.Availability,
                     engine: String = "piper", kind: ModelsByLanguageViewState.Kind = .local) -> ModelsByLanguageViewState.Row {
        .init(id: id, kind: kind, title: title, detail: "medium",
              selection: engine == "piper" ? TtsSelection(engine: "piper", modelID: id, voice: nil) : .engineDefault(engine),
              availability: availability, isChosen: false)
    }

    func testSwitchListsOnlyReadyModelsOfTheBooksLanguage() {
        let picker = ReaderVoicePicker(selection: TtsSelection(engine: "piper", modelID: "pt_BR-faber-medium", voice: nil)) { _ in }
        let content = ReaderModelSwitch.content(language: "pt", rows: [
            row("pt_BR-faber-medium", "Faber", .ready), row("pt_BR-cadu-medium", "Cadu", .downloadable(bytes: 10)),
            row("pt_BR-jeff-medium", "Jeff", .unavailable), row("edge", "Edge", .needsConsent, engine: "edge", kind: .online),
            row("system", "System", .ready, engine: "system"),
        ], picker: picker)
        XCTAssertEqual(content.choices.map(\.title), ["Faber", "System"], "Only downloaded models of the language")
        XCTAssertEqual(content.choices.first?.selected, true)
        XCTAssertTrue(content.choices.allSatisfy(\.available))
        XCTAssertFalse(content.hasNoModel)
        XCTAssertEqual(content.language, "pt")
    }

    func testSwitchWithNoReadyModelKeepsTheActiveVoiceVisibleAndOffersTheModelsScreen() {
        let picker = ReaderVoicePicker(selection: TtsSelection(engine: "piper", modelID: "pt_BR-faber-medium", voice: nil),
                                       resolvedTitle: "Faber") { _ in }
        let content = ReaderModelSwitch.content(language: "en", rows: [
            row("en_US-ljspeech-high", "LJ Speech", .downloadable(bytes: 10)),
        ], picker: picker)
        XCTAssertTrue(content.hasNoModel, "No model qualifies: the menu leads to the Models screen")
        XCTAssertEqual(content.choices.map(\.title), ["Faber"])
        XCTAssertEqual(content.choices.first?.available, false, "The active voice is shown but cannot be re-picked")
    }

    func testChoosingInTheSwitchKeepsTheLanguageChoiceAndSwitchesImmediately() throws {
        let suite = "reader-switch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        var changes: [TtsSelection] = []
        let picker = ReaderVoicePicker(selection: .systemDefault) { changes.append($0) }
        let cadu = TtsSelection(engine: "piper", modelID: "pt_BR-cadu-medium", voice: nil)
        let content = ReaderModelSwitch.content(language: "pt", rows: [row("pt_BR-cadu-medium", "Cadu", .ready)], picker: picker)
        content.choose(cadu, picker: picker, settings: settings)
        XCTAssertEqual(changes, [cadu], "The live switch restarts at once through the existing picker")
        XCTAssertEqual(settings.languageModelChoices["pt"], cadu, "The language's persisted choice follows the switch")
        content.choose(.systemDefault, picker: picker, settings: settings)
        XCTAssertEqual(changes, [cadu], "Choosing the active voice changes nothing")
    }

    // MARK: READER-MODEL-MENU-INSTANT — the model button must open the menu at once

    private func menuRequest(_ suite: String) throws -> (ReaderVoicePickerRequest, ReaderVoicePicker, UserDefaults) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        let book = BookEntity(id: "menu-book-\(suite)", title: "Book", bookmark: Data([1]),
            displayFilename: "book.epub", addedAt: Date())
        let request = ReaderVoicePickerRequest(settings: settings, library: LibraryStore(defaults: defaults),
            player: AudioPlayer(), currentContext: { .init(book: book) }, restart: { _, _ in })
        let picker = try XCTUnwrap(request.picker())
        return (request, picker, defaults)
    }

    /// Neither the system-voice scan nor the catalogue listing may run on the main thread: both blocked the
    /// reader (and so the tap that opens the menu) for a noticeable time.
    func testOpeningTheModelMenuNeverBlocksTheMainThreadWithTheVoiceScanOrTheCatalogue() async throws {
        ReaderModelSwitch.resetCachesForTesting()
        let suite = "menu-main-\(UUID().uuidString)"
        let (request, picker, defaults) = try menuRequest(suite)
        defer { defaults.removePersistentDomain(forName: suite); ReaderModelSwitch.resetCachesForTesting() }
        final class Probe: ModelsByLanguageModelTests.FakeSource, @unchecked Sendable {
            let lock2 = NSLock(); var snapshotOnMain: [Bool] = []
            override func snapshot(language: String) async throws -> SpeechModelSnapshot {
                lock2.lock(); snapshotOnMain.append(Thread.isMainThread); lock2.unlock()
                return try await super.snapshot(language: language)
            }
        }
        let source = Probe()
        let voicesOnMain = LockedBool()
        let content = await ReaderModelSwitch.content(picker: picker, request: request, source: source,
            systemVoiceLanguages: { voicesOnMain.record(Thread.isMainThread); return ["pt"] },
            languageOf: { _ in "pt-BR" })
        XCTAssertNotNil(content)
        XCTAssertEqual(voicesOnMain.values, [false], "The installed-voice scan must run off the main thread")
        XCTAssertEqual(source.snapshotOnMain, [false], "The catalogue listing must run off the main thread")
    }

    /// Once warmed for the book, the menu content comes straight from the cache even when the catalogue is slow.
    func testTheModelMenuOpensInstantlyFromTheCacheWhenTheCatalogueIsSlow() async throws {
        ReaderModelSwitch.resetCachesForTesting()
        let suite = "menu-cache-\(UUID().uuidString)"
        let (request, picker, defaults) = try menuRequest(suite)
        defer { defaults.removePersistentDomain(forName: suite); ReaderModelSwitch.resetCachesForTesting() }
        let fast = ModelsByLanguageModelTests.FakeSource()
        let warmed = await ReaderModelSwitch.content(picker: picker, request: request, source: fast,
            systemVoiceLanguages: { ["pt"] }, languageOf: { _ in "pt-BR" })
        XCTAssertNotNil(warmed)

        let slow = ModelsByLanguageModelTests.FakeSource()
        slow.snapshotDelayNanoseconds = 3_000_000_000
        let started = Date()
        let again = await ReaderModelSwitch.content(picker: picker, request: request, source: slow,
            systemVoiceLanguages: { ["pt"] }, languageOf: { _ in "pt-BR" })
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertNotNil(again)
        XCTAssertLessThan(elapsed, 0.3, "The menu must not wait for the catalogue when it was already listed for this book")
        XCTAssertEqual(again?.choices.map(\.title), warmed?.choices.map(\.title))
    }

    // MARK: VOICE-SWITCH-RESUME-EXACT — a voice change continues from the same text, whatever the voices' speeds

    private struct SwitchFixture {
        let player: AudioPlayer
        let book: BookEntity
        let text: String
        let jobID: String
        let tearDown: () -> Void
    }

    /// A listening job of `engine` playing chapter 19 of `book` with the player's clock at `seconds` of `duration`.
    /// Audio position carries a sentence id only when `sentenceID` is given: engines without timing publish none.
    private func playingFixture(engine: String, voice: String, seconds: Double, duration: Double,
                                sentenceID: (String) -> String?) throws -> SwitchFixture {
        let suite = "voice-switch-resume-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let book = BookEntity(id: "resume-\(suite)", title: "Book", bookmark: Data([1]),
            displayFilename: "book.epub", addedAt: Date())
        let text = (0..<400).map { "Sentence number \($0) of the chapter." }.joined(separator: " ")
        let chapter = NativeReaderTestHarness.chapter(text, index: 20)
        LocalFulltextCache.save(EbookFulltext(jobId: "fixture", bookTitle: "Book", bookAuthor: nil, chapters: [chapter]),
                                bookId: book.id)
        let snapshot = JobSnapshot(jobId: "job-\(engine)", state: "running", bookTitle: "Book", bookAuthor: nil,
            coverUrl: nil, coverMimeType: nil, engine: engine, voice: voice, language: "pt-BR", progressPercent: 0,
            chaptersTotal: nil, chaptersCompleted: 0, chapterProgress: [], outputs: nil, logUrl: nil, error: nil,
            lastActivityAt: nil, chapterIndexBase: 0)
        player.play(snapshot: snapshot, restoreAutoplay: false)
        player.isConverting = true
        player.playbackStreamingChapterChanged(19)
        let item = NSObject()
        let sentence = sentenceID(chapter.splitSentences().count > 150 ? chapter.splitSentences()[150].id : "")
        for step in 0..<2 {
            player.playbackClock.audioOutput.sample(item: ObjectIdentifier(item), seconds: seconds + Double(step) * 0.1,
                isOutputting: true, position: .init(chapterIndex: 19, seconds: seconds + Double(step) * 0.1,
                    duration: duration, sentenceID: sentence, itemSeconds: 3 + Double(step) * 0.1, itemDuration: 8))
        }
        return SwitchFixture(player: player, book: book, text: text, jobID: snapshot.jobId) {
            player.stop(); LocalFulltextCache.evictInMemoryPayload(bookId: book.id)
            defaults.removePersistentDomain(forName: suite)
            _ = item
        }
    }

    /// The trace of the failing Piper → System switch: the audio position carried no sentence id and no alignment, so
    /// the change fell back to the OLD voice's chapter seconds. A new voice with another speed generates the chapter
    /// from its start and the player waited forever for second 2026 of audio that did not exist yet. The change must
    /// carry the TEXT position (the slider's time-to-text map), from any engine, so the new job starts there.
    func testEveryEngineCarriesATextPositionWhenTheAudioHasNoSentenceTiming() throws {
        for (engine, voice) in [("piper", "pt_BR-faber-medium"), ("system", "Luciana (installed.luciana)"),
                                ("edge", "pt-BR-AntonioNeural")] {
            let fixture = try playingFixture(engine: engine, voice: voice, seconds: 2_026.8, duration: 2_725) { _ in nil }
            defer { fixture.tearDown() }
            let change = try XCTUnwrap(ReaderVoiceChange.capture(player: fixture.player, book: fixture.book,
                starting: nil, ownedJobID: fixture.jobID), "\(engine): a playing job can be switched")
            XCTAssertNil(change.seek, "\(engine): the old voice's seconds must not be replayed on the new voice's clock")
            let ratio = try XCTUnwrap(change.pageRatio, "\(engine): the change must carry a text position")
            XCTAssertEqual(ratio, 2_026.8 / 2_725, accuracy: 0.01, "\(engine): resumes where the clock was in the chapter")
            XCTAssertEqual(change.chapter, 19, engine)
        }
    }

    /// With sentence timing the exact sentence is kept — for every engine, unchanged by the fix above.
    func testEveryEngineResumesAtTheSpokenSentenceWhenTheAudioHasItsId() throws {
        for (engine, voice) in [("piper", "pt_BR-faber-medium"), ("system", "Luciana (installed.luciana)"),
                                ("edge", "pt-BR-AntonioNeural")] {
            let fixture = try playingFixture(engine: engine, voice: voice, seconds: 100, duration: 2_725) { $0 }
            defer { fixture.tearDown() }
            let chapter = NativeReaderTestHarness.chapter(fixture.text, index: 20)
            let sentence = chapter.splitSentences()[150]
            let before = (fixture.text as NSString).substring(to: (fixture.text as NSString).range(of: sentence.text).location)
            let expected = Double(before.unicodeScalars.count) / Double(fixture.text.unicodeScalars.count)
            let change = try XCTUnwrap(ReaderVoiceChange.capture(player: fixture.player, book: fixture.book,
                starting: nil, ownedJobID: fixture.jobID), engine)
            XCTAssertNil(change.seek, engine)
            XCTAssertEqual(try XCTUnwrap(change.pageRatio, engine), expected, accuracy: 0.002, "\(engine): the spoken sentence")
        }
    }
}

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [Bool] = []
    func record(_ value: Bool) { lock.lock(); values.append(value); lock.unlock() }
}
