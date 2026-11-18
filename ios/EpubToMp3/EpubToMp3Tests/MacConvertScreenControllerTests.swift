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
                       source: source, directory: directory)
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
