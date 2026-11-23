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
}
