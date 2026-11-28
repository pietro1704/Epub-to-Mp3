#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MacConvertScreenControllerTests: XCTestCase {
    private struct Fixture {
        let settings: AppSettings
        let library: LibraryStore
        let book: BookEntity
        let source: URL
        let directory: URL
        let defaults: UserDefaults
    }

    private func fixture() throws -> Fixture {
        let suite = "MacConvertScreen.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let source = try EpubFixture.createWithChapters(["First chapter", "Second chapter"])
        let library = LibraryStore(defaults: defaults, defaultsKey: "library", importDirectory: directory)
        let book = try library.importBook(from: source)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: source)
        }
        return Fixture(settings: AppSettings(defaults: defaults), library: library, book: book,
                       source: source, directory: directory, defaults: defaults)
    }

    private func result(jobID: String, directory: URL) -> RustConversionCoordinator.Result {
        .init(jobID: jobID,
              manifestJSON: Data("{\"manifest\":{\"jobId\":\"\(jobID)\",\"title\":\"Converted fixture\",\"author\":\"Author\",\"chapters\":[]}}".utf8),
              outputDirectory: directory)
    }

    func testFormStartsNearTheTopAndKeepsSubmitReachableInAShortWindow() throws {
        let fixture = try fixture()
        let controller = MacConvertScreenController(settings: fixture.settings, library: fixture.library)
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        window.setContentSize(NSSize(width: 1000, height: 850))
        controller.view.layoutSubtreeIfNeeded()
        let fileLabel = controller.form.fileLabel.convert(controller.form.fileLabel.bounds, to: controller.view)
        let topInset = controller.view.isFlipped ? fileLabel.minY : controller.view.bounds.maxY - fileLabel.maxY
        XCTAssertLessThan(topInset, 120, "Short forms must start at the top, not the bottom of the viewport")
        window.setContentSize(NSSize(width: 700, height: 430))
        controller.view.layoutSubtreeIfNeeded()
        controller.form.submit.scrollToVisible(controller.form.submit.bounds)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(controller.form.submit.visibleRect.height, 0)
        let submit = controller.form.submit.convert(controller.form.submit.bounds, to: controller.view)
        XCTAssertGreaterThanOrEqual(submit.minX, 0)
        XCTAssertLessThanOrEqual(submit.maxX, controller.view.bounds.maxX)
    }

    func testLibraryContextStartsWithDefaultsAndRecordsOnlyTheSelectedBook() async throws {
        let fixture = try fixture()
        var request: (String, Int32, Int32, ConversionOptions?)?
        let model = ConvertViewModel(session: ManualConversionSession(executor: { file, jobID, start, end, options, _, _ in
            XCTAssertEqual(try BookContentIdentity.hash(of: file), fixture.book.id)
            request = (jobID, start, end, options)
            return self.result(jobID: jobID, directory: fixture.directory)
        }))
        let controller = MacConvertScreenController(settings: fixture.settings, library: fixture.library, viewModel: model)
        _ = controller.view
        controller.form.chapters.stringValue = "8-9"
        controller.form.forceReprocess.state = .on
        await controller.selectLibraryBook(fixture.book.id)
        XCTAssertEqual(request?.1, -1)
        XCTAssertEqual(request?.2, -1)
        XCTAssertEqual(request?.3?.ttsPreferences, fixture.settings.ttsPreferences)
        XCTAssertEqual(request?.3?.forceReprocess, false)
        XCTAssertEqual(controller.selectedBookID, fixture.book.id)
        XCTAssertEqual(fixture.library.books.first(where: { $0.id == fixture.book.id })?.lastJobId, request?.0)
        XCTAssertEqual(controller.form.result.stringValue, L10n.string("convert.completed"))
        XCTAssertTrue(controller.form.submit.isEnabled)
        XCTAssertFalse(controller.form.revealResult.isHidden)
        XCTAssertEqual(MacSidebarPresentation.Destination.convert.title, L10n.string("convert.title"))
    }

    func testPronunciationUsesSelectedContentIdentityAndManualFieldsReachSharedSession() async throws {
        let fixture = try fixture()
        var editedBook: String?
        var bounds: (Int32, Int32)?
        var options: ConversionOptions?
        let model = ConvertViewModel(session: ManualConversionSession(executor: { _, jobID, start, end, selected, _, _ in
            bounds = (start, end)
            options = selected
            return self.result(jobID: jobID, directory: fixture.directory)
        }))
        let controller = MacConvertScreenController(settings: fixture.settings, library: fixture.library, viewModel: model,
                                                   presentPronunciation: { bookID, _ in editedBook = bookID })
        _ = controller.view
        XCTAssertFalse(controller.form.pronunciation.isEnabled)
        await controller.selectLibraryBook(fixture.book.id, startImmediately: false)
        controller.form.pronunciation.performClick(nil)
        XCTAssertEqual(editedBook, fixture.book.id)
        controller.form.chapters.stringValue = "8-9"
        controller.form.language.stringValue = "pt-BR"
        controller.form.voice.stringValue = "speaker-0"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.form.voice))
        controller.form.forceReprocess.state = .on
        await controller.submit()
        XCTAssertEqual(bounds?.0, 8)
        XCTAssertEqual(bounds?.1, 9)
        XCTAssertEqual(options?.voice, "speaker-0")
        XCTAssertEqual(options?.language, "pt-BR")
        XCTAssertEqual(options?.forceReprocess, true)
        XCTAssertNil(options?.ttsPreferences?.secondary, "Editing voice must not silently enable fallback")
    }

    func testSourceIdentityMismatchCannotStartOrEditAnotherBooksPronunciation() async throws {
        let fixture = try fixture()
        var calls = 0
        let model = ConvertViewModel(session: ManualConversionSession(executor: { _, jobID, _, _, _, _, _ in
            calls += 1
            return self.result(jobID: jobID, directory: fixture.directory)
        }))
        let controller = MacConvertScreenController(settings: fixture.settings, library: fixture.library, viewModel: model,
                                                   resolveBookFile: { _ in fixture.source })
        await controller.selectLibraryBook("another-book")
        XCTAssertEqual(calls, 0)
        XCTAssertNil(controller.selectedBookID)
        XCTAssertNil(model.selectedFile)
        XCTAssertFalse(controller.form.pronunciation.isEnabled)
        XCTAssertFalse(controller.form.submit.isEnabled)
        XCTAssertFalse(controller.form.failure.stringValue.isEmpty)
        XCTAssertFalse(controller.isPreparingSource)
    }

    func testLateSourceResolutionCannotReplaceNewerSelection() async throws {
        let fixture = try fixture()
        let otherSource = try EpubFixture.createWithChapters(["A different book"])
        defer { try? FileManager.default.removeItem(at: otherSource) }
        let otherID = try BookContentIdentity.hash(of: otherSource)
        let gate = ManualConversionGate()
        defer { gate.release() }
        let entered = expectation(description: "First source resolver started")
        let controller = MacConvertScreenController(settings: fixture.settings, library: fixture.library,
            resolveBookFile: { bookID in
                if bookID == fixture.book.id {
                    entered.fulfill()
                    await gate.wait()
                    return fixture.source
                }
                return otherSource
            })
        let pending = Task { await controller.selectLibraryBook(fixture.book.id, startImmediately: false) }
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertFalse(controller.form.pronunciation.isEnabled)
        await controller.selectLibraryBook(otherID, startImmediately: false)
        gate.release()
        await pending.value
        XCTAssertEqual(controller.selectedBookID, otherID)
        XCTAssertEqual(controller.form.fileLabel.stringValue, otherSource.lastPathComponent)
        XCTAssertTrue(controller.form.pronunciation.isEnabled)
    }

    func testSourceChangedAfterSelectionCannotConvertUnderPreviousBookIdentity() async throws {
        let fixture = try fixture()
        var calls = 0
        let model = ConvertViewModel(session: ManualConversionSession(executor: { _, jobID, _, _, _, _, _ in
            calls += 1
            return self.result(jobID: jobID, directory: fixture.directory)
        }))
        let controller = MacConvertScreenController(settings: fixture.settings, library: fixture.library, viewModel: model)
        await controller.selectLibraryBook(fixture.book.id, startImmediately: false)
        try Data("changed source".utf8).write(to: XCTUnwrap(model.selectedFile))
        await controller.submit()
        XCTAssertEqual(calls, 0)
        XCTAssertNil(controller.selectedBookID)
        XCTAssertNil(fixture.library.books.first?.lastJobId)
        XCTAssertFalse(controller.form.pronunciation.isEnabled)
        XCTAssertFalse(controller.form.failure.isHidden)
    }

    private func convertedController(
        _ fixture: Fixture, audioExtension: String,
        chooseExport: (() async -> MacConvertScreenController.ExportChoice?)? = nil
    ) async throws -> (MacConvertScreenController, URL) {
        let output = fixture.directory.appendingPathComponent("converted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try CompletedMP3Fixture.data(frames: 80).write(to: output.appendingPathComponent("one.\(audioExtension)"))
        let model = ConvertViewModel(session: ManualConversionSession(executor: { _, jobID, _, _, _, _, _ in
            let manifest = "{\"manifest\":{\"jobId\":\"\(jobID)\",\"title\":\"Converted fixture\",\"author\":\"Author\","
                + "\"chapters\":[{\"title\":\"Um\",\"filename\":\"one.\(audioExtension)\",\"textChars\":3}]}}"
            return .init(jobID: jobID, manifestJSON: Data(manifest.utf8), outputDirectory: output)
        }))
        let external = try EpubFixture.createWithChapters(["A book that is not in the library"])
        addTeardownBlock { try? FileManager.default.removeItem(at: external) }
        let controller = MacConvertScreenController(settings: fixture.settings, library: fixture.library,
            viewModel: model, inboxDirectory: fixture.directory.appendingPathComponent("inbox"),
            chooseExport: chooseExport)
        _ = controller.view
        await controller.selectDocument(external)
        XCTAssertTrue(controller.form.addToLibrary.isHidden)
        XCTAssertTrue(controller.form.exportAudio.isHidden)
        await controller.submit()
        return (controller, output)
    }

    func testFinishedConversionAddsTheBookWithItsAudioOnlyWhenAsked() async throws {
        let fixture = try fixture()
        let (controller, _) = try await convertedController(fixture, audioExtension: "mp3")
        XCTAssertEqual(fixture.library.books.map(\.id), [fixture.book.id], "Nothing is added automatically")
        XCTAssertFalse(controller.form.addToLibrary.isHidden)
        XCTAssertEqual(controller.form.addToLibrary.title, L10n.string("convert.addToLibrary"))

        await controller.addResultToLibrary()

        XCTAssertEqual(fixture.library.books.count, 2)
        let added = try XCTUnwrap(fixture.library.books.first { $0.id != fixture.book.id })
        XCTAssertNotNil(added.lastJobId)
        XCTAssertTrue(controller.form.addToLibrary.isHidden)
        XCTAssertEqual(controller.form.delivery.stringValue, L10n.string("convert.addedToLibrary"))
    }

    func testExportWritesTheChosenLayoutAndFormatToTheChosenFolder() async throws {
        let fixture = try fixture()
        let destination = fixture.directory.appendingPathComponent("exported", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let (controller, _) = try await convertedController(fixture, audioExtension: "mp3") {
            .init(directory: destination, layout: .perChapter, format: .m4a)
        }
        XCTAssertFalse(controller.form.exportAudio.isHidden)
        XCTAssertTrue(controller.form.exportAudio.isEnabled)

        await controller.exportResult()

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["01 - Um.m4a"])
        XCTAssertEqual(controller.form.delivery.stringValue,
                       ManualConversionDelivery.doneMessage(fileCount: 1))
    }

    func testExportIsDisabledWithTheReasonWhenThereIsNoMP3Audio() async throws {
        let fixture = try fixture()
        let (controller, _) = try await convertedController(fixture, audioExtension: "wav")
        XCTAssertFalse(controller.form.exportAudio.isHidden)
        XCTAssertFalse(controller.form.exportAudio.isEnabled)
        XCTAssertEqual(controller.form.delivery.stringValue, L10n.string("convert.export.needsPiper"))
    }

    func testFailureAllowsRetryWithoutRecordingAJob() async throws {
        let fixture = try fixture()
        var calls = 0
        let model = ConvertViewModel(session: ManualConversionSession(executor: { _, jobID, _, _, _, _, _ in
            calls += 1
            if calls == 1 { throw NSError(domain: "ConversionFixture", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "Provider failed"]) }
            return self.result(jobID: jobID, directory: fixture.directory)
        }))
        let controller = MacConvertScreenController(settings: fixture.settings, library: fixture.library, viewModel: model)
        await controller.selectLibraryBook(fixture.book.id)
        XCTAssertEqual(model.session.phase, .failed)
        XCTAssertEqual(controller.form.failure.stringValue, "Provider failed")
        XCTAssertNil(fixture.library.books.first?.lastJobId)
        XCTAssertTrue(controller.form.submit.isEnabled)
        await controller.submit()
        XCTAssertEqual(model.session.phase, .completed)
        XCTAssertNotNil(fixture.library.books.first?.lastJobId)
        XCTAssertTrue(controller.form.failure.isHidden)
    }

    func testCancellationWaitsForWriterAndKeepsSelectionStableUntilRetry() async throws {
        let fixture = try fixture()
        let gate = ManualConversionGate()
        defer { gate.release() }
        let started = expectation(description: "Manual writer started")
        var calls = 0
        let model = ConvertViewModel(session: ManualConversionSession(executor: { _, jobID, _, _, _, update, _ in
            calls += 1
            update?(.init(jobId: jobID, state: "running", chapterIndex: 0, chaptersTotal: 2,
                          chaptersCompleted: 1, percent: 50, engine: "piper", message: "Fixture progress"))
            if calls == 1 { started.fulfill(); await gate.wait() }
            return self.result(jobID: jobID, directory: fixture.directory)
        }))
        let controller = MacConvertScreenController(settings: fixture.settings, library: fixture.library, viewModel: model)
        let pending = Task { await controller.selectLibraryBook(fixture.book.id) }
        await fulfillment(of: [started], timeout: 1)
        await controller.submit()
        await controller.selectLibraryBook("another-book")
        XCTAssertEqual(controller.selectedBookID, fixture.book.id)
        XCTAssertEqual(calls, 1)
        // The shared session publishes synchronously; AppKit receives the update
        // on its run loop. Force one ordinary lifecycle refresh before the click.
        controller.viewWillAppear()
        XCTAssertFalse(controller.form.pronunciation.isEnabled)
        controller.form.cancel.performClick(nil)
        XCTAssertEqual(model.session.phase, .cancelling)
        XCTAssertFalse(controller.form.submit.isEnabled)
        gate.release()
        await pending.value
        XCTAssertEqual(model.session.phase, .cancelled)
        XCTAssertNil(fixture.library.books.first?.lastJobId)
        XCTAssertTrue(controller.form.result.isHidden)
        XCTAssertEqual(controller.form.status.stringValue, L10n.string("convert.cancelled"))
        await controller.submit()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(model.session.phase, .completed)
    }

    func testAudioRemovalDuringLibraryConversionDoesNotRecordTheRemovedJob() async throws {
        let fixture = try fixture()
        let gate = ManualConversionGate()
        defer { gate.release() }
        let started = expectation(description: "Manual writer is waiting for output")
        var returned = false
        let model = ConvertViewModel(session: ManualConversionSession(executor: { _, jobID, _, _, _, _, _ in
            started.fulfill()
            await gate.wait()
            returned = true
            return self.result(jobID: jobID, directory: fixture.directory)
        }))
        let controller = MacConvertScreenController(settings: fixture.settings, library: fixture.library, viewModel: model)
        let pending = Task { await controller.selectLibraryBook(fixture.book.id) }
        await fulfillment(of: [started], timeout: 1)
        NotificationCenter.default.post(name: RustConversionOutputStore.willRemoveAudio,
                                        object: nil, userInfo: ["bookID": fixture.book.id])
        gate.release()
        await pending.value
        XCTAssertTrue(returned)
        XCTAssertNotEqual(model.session.phase, .completed)
        XCTAssertNil(fixture.library.books.first(where: { $0.id == fixture.book.id })?.lastJobId,
                     "An output removed while conversion was pending must not be recorded again")
        try await fixture.library.flushPersistence()
        let reloaded = LibraryStore(defaults: fixture.defaults, defaultsKey: "library",
                                    importDirectory: fixture.directory)
        XCTAssertNil(reloaded.books.first(where: { $0.id == fixture.book.id })?.lastJobId)
        XCTAssertTrue(controller.form.revealResult.isHidden)
    }

    func testReplacedDocumentSelectionDiscardsItsInboxCopyAndNeverTouchesLibraryFiles() async throws {
        let fixture = try fixture()
        let manager = FileManager.default
        let inbox = manager.temporaryDirectory.appendingPathComponent("inbox-\(UUID().uuidString)", isDirectory: true)
        let pickDirectory = manager.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: inbox, withIntermediateDirectories: true)
        try manager.createDirectory(at: pickDirectory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: inbox); try? manager.removeItem(at: pickDirectory) }
        let first = pickDirectory.appendingPathComponent("First.epub")
        let second = pickDirectory.appendingPathComponent("Second.epub")
        try manager.copyItem(at: fixture.source, to: first)
        try manager.copyItem(at: fixture.source, to: second)
        let controller = MacConvertScreenController(settings: fixture.settings, library: fixture.library,
                                                   inboxDirectory: inbox)
        func copies() throws -> [String] { try manager.contentsOfDirectory(atPath: inbox.path).sorted() }

        await controller.selectDocument(first)
        XCTAssertEqual(try copies().count, 1)
        let firstCopy = try XCTUnwrap(controller.currentSelectionForTesting)
        await controller.selectDocument(second)
        XCTAssertEqual(try copies().count, 1, "A replaced selection must not leave its copy behind")
        XCTAssertFalse(manager.fileExists(atPath: firstCopy.path))
        let secondCopy = try XCTUnwrap(controller.currentSelectionForTesting)
        XCTAssertTrue(manager.fileExists(atPath: secondCopy.path))
        XCTAssertTrue(manager.fileExists(atPath: first.path) && manager.fileExists(atPath: second.path),
                      "The user's own files are never deleted")

        await controller.selectLibraryBook(fixture.book.id, startImmediately: false)
        XCTAssertEqual(try copies(), [], "Selecting a library book discards the last imported copy")
        XCTAssertTrue(manager.fileExists(atPath: fixture.source.path))
        XCTAssertNotNil(controller.currentSelectionForTesting)
    }

    func testSecondBookIsNotDroppedSilentlyWhileAConversionRuns() async throws {
        let fixture = try fixture()
        let gate = ManualConversionGate()
        defer { gate.release() }
        let started = expectation(description: "First conversion running")
        let model = ConvertViewModel(session: ManualConversionSession(executor: { _, jobID, _, _, _, _, _ in
            started.fulfill()
            await gate.wait()
            return self.result(jobID: jobID, directory: fixture.directory)
        }))
        let controller = MacConvertScreenController(settings: fixture.settings, library: fixture.library, viewModel: model)
        let pending = Task { await controller.selectLibraryBook(fixture.book.id) }
        await fulfillment(of: [started], timeout: 1)
        await controller.selectLibraryBook("another-book")
        XCTAssertEqual(controller.form.failure.stringValue, L10n.string("convert.error.busyWithAnotherBook"))
        XCTAssertFalse(controller.form.failure.isHidden)
        XCTAssertEqual(controller.selectedBookID, fixture.book.id, "The running conversion keeps its form")
        gate.release()
        await pending.value
    }

    func testComicLibraryBookIsRefusedWithoutStartingAConversion() async throws {
        let fixture = try fixture()
        let comic = BookEntity(id: "comic-book", title: "Comic", bookmark: Data([1]), displayFilename: "Comic.cbz",
                               addedAt: .distantPast, lastJobId: nil, fileType: .cbz)
        try fixture.defaults.set(JSONEncoder().encode([comic]), forKey: "library")
        let library = LibraryStore(defaults: fixture.defaults, defaultsKey: "library")
        var resolved = 0
        var calls = 0
        let model = ConvertViewModel(session: ManualConversionSession(executor: { _, jobID, _, _, _, _, _ in
            calls += 1
            return self.result(jobID: jobID, directory: fixture.directory)
        }))
        let controller = MacConvertScreenController(settings: fixture.settings, library: library, viewModel: model,
                                                   resolveBookFile: { _ in resolved += 1; return fixture.source })
        await controller.selectLibraryBook("comic-book")
        XCTAssertEqual(resolved, 0)
        XCTAssertEqual(calls, 0)
        XCTAssertNil(controller.selectedBookID)
        XCTAssertEqual(controller.form.failure.stringValue, L10n.string("convert.error.unsupportedBookType"))
        XCTAssertFalse(controller.isPreparingSource)
    }

    func testInvalidCompletedManifestDoesNotRecordSuccessfulLibraryConversion() async throws {
        let fixture = try fixture()
        let model = ConvertViewModel(session: ManualConversionSession(executor: { _, jobID, _, _, _, _, _ in
            .init(jobID: jobID, manifestJSON: Data("invalid manifest".utf8), outputDirectory: fixture.directory)
        }))
        let controller = MacConvertScreenController(settings: fixture.settings, library: fixture.library, viewModel: model)
        await controller.selectLibraryBook(fixture.book.id)
        XCTAssertNil(fixture.library.books.first?.lastJobId)
        XCTAssertTrue(controller.form.result.isHidden)
        XCTAssertTrue(controller.form.revealResult.isHidden)
        XCTAssertFalse(controller.form.failure.isHidden)
    }
}
#endif
