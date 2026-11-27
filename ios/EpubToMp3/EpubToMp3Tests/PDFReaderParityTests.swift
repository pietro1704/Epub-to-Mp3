#if os(iOS)
import PDFKit
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class PDFReaderParityTests: XCTestCase {
    func testPhysicalPDFPagesMapToTheBundledRustNarrationAxis() throws {
        let url = try PdfFixture.createMultiPage(pages: [
            (heading: "First", body: "First audible passage, ação e coração."),
            (heading: "Second", body: "Second audible passage with another sentence.")])
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(PDFDocument(url: url))
        let metadata = try ConverterFFIAdapter().openBook(at: url).metadataJSON
        let map = try PDFReadingAudioMap(metadata: metadata,
            pageTexts: (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" })
        XCTAssertEqual(map.anchor(page: 0)?.chapterIndex, 0)
        XCTAssertEqual(map.anchor(page: 1)?.chapterIndex, 1)
        XCTAssertEqual(map.anchor(page: 1)?.ratio, 0)
        let body = (document.page(at: 1)?.string ?? "") as NSString
        let phrase = body.range(of: "another")
        XCTAssertNotEqual(phrase.location, NSNotFound)
        XCTAssertGreaterThan(try XCTUnwrap(map.anchor(page: 1, character: phrase.location)?.ratio), 0)
        XCTAssertNil(map.anchor(page: 2))
    }

    func testRepeatedPagesRemainDistinctAndRatiosUseRustUnicodeScalars() throws {
        let text = "😀Prefixo\n\nMesmo trecho.\n\nMesmo trecho."
        let metadata = try JSONSerialization.data(withJSONObject: ["chapters": [
            ["index": "1", "name": "One chapter", "sourcePath": "page-1", "text": text]]])
        let map = try PDFReadingAudioMap(metadata: metadata, pageTexts: ["😀Prefixo", "Mesmo trecho.", "Mesmo trecho.", "Unrelated text"])
        let first = try XCTUnwrap(map.anchor(page: 1))
        let second = try XCTUnwrap(map.anchor(page: 2))
        XCTAssertEqual(first.chapterIndex, second.chapterIndex)
        XCTAssertGreaterThan(second.ratio, first.ratio)
        let expected = Double("😀Prefixo\n\n".unicodeScalars.count) / Double(text.unicodeScalars.count)
        XCTAssertEqual(first.ratio, expected, accuracy: 0.000001)
        XCTAssertNil(map.anchor(page: 3), "Never substitute an unrelated paragraph or invent OCR text")
    }

    func testPlaybackLocationBetweenWordsOpensTheLaterPageOfOneChapter() throws {
        let url = try PdfFixture.createMultiPage(pages: [
            (heading: "First", body: "An earlier passage."),
            (heading: "Second", body: "Later. Continue reading here."),
            (heading: "Third", body: "Unmapped later material.")])
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(PDFDocument(url: url))
        let first = try XCTUnwrap(document.page(at: 0)?.string)
        let second = try XCTUnwrap(document.page(at: 1)?.string)
        let text = first + "\n\n" + second
        let punctuation = (text as NSString).range(of: ". ", options: .backwards)
        guard punctuation.location != NSNotFound else { return XCTFail("The PDF fixture must contain a sentence boundary") }
        let metadata = try JSONSerialization.data(withJSONObject: ["chapters": [
            ["index": "1", "name": "One chapter", "sourcePath": "page-1", "text": text]]])
        let suite = "pdf-playback-location-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = UIViewController()
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        let previousWindow = scene?.windows.first(where: \.isKeyWindow)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = host
        let view = ReaderPDFView(frame: window.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(view)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        let pdf = ReaderPDFPresentation(view: view, bookID: "fixture", defaults: defaults)
        pdf.load(document: document, metadata: metadata)
        view.layoutIfNeeded()
        XCTAssertEqual(pdf.currentPage, 0)

        let player = AudioPlayer()
        let snapshot = try JSONDecoder().decode(JobSnapshot.self, from: Data("""
            {"jobId":"pdf-location","state":"finished","chapterIndexBase":1,"chapterProgress":[
                {"index":1,"status":"completed","downloadUrl":"file:///tmp/pdf-location.mp3",
                 "textOffset":\(punctuation.location + 1)}]}
            """.utf8))
        player.setSnapshot(snapshot)
        player.services.observation.publishCurrentChapter()
        let location = try XCTUnwrap(ReaderPlaybackLocation(player: player))
        let offset = location.characterOffset(chapterText: text, renderedText: text)
        let match = try XCTUnwrap(pdf.audioMap?.displayLocation(chapter: 0, character: offset))
        XCTAssertEqual(match.page, 1)
        XCTAssertEqual((second as NSString).substring(with: NSRange(location: match.character, length: 1)), "C")
        for layout in [ReaderLayout.scrolling, .paginated] {
            pdf.applyLayout(layout)
            pdf.goToChapter(0)
            XCTAssertEqual(pdf.currentPage, 0)
            pdf.revealPlaybackLocation(location)
            view.layoutIfNeeded()
            XCTAssertEqual(pdf.currentPage, 1, "The playback page must be visible in \(layout)")
        }
    }

    func testListeningFromATextlessCoverStartsAtTheNextPageWithText() throws {
        let url = try PdfFixture.createMultiPage(pages: [
            (heading: "", body: ""),
            (heading: "Second page", body: "Second readable passage.")])
        defer { try? FileManager.default.removeItem(at: url) }
        let suite = "pdf-cover-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let pdf = ReaderPDFPresentation(view: view, bookID: "fixture", defaults: defaults)
        pdf.load(document: try XCTUnwrap(PDFDocument(url: url)),
                 metadata: try ConverterFFIAdapter().openBook(at: url).metadataJSON)
        view.layoutIfNeeded()
        XCTAssertEqual(pdf.currentPage, 0)
        var played: PDFReadingAudioMap.Anchor?
        pdf.onPlayFrom = { played = $0 }

        pdf.playFromCurrentPosition()

        XCTAssertNotNil(played, "A cover without text must not block listening")
        XCTAssertEqual(played, pdf.audioMap?.anchor(page: 1))
    }

    /// PDF parity with the EPUB reader: pausing keeps the passage marked, a jump drops the old mark.
    func testPDFKeepsTheHighlightWhilePausedUntilTheNarrationMoves() async throws {
        let url = try PdfFixture.createMultiPage(pages: [
            (heading: "Narration", body: "A synthetic sentence to narrate.")])
        defer { try? FileManager.default.removeItem(at: url) }
        let suite = "pdf-paused-highlight-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        // The player reads the reader location from its resume store's defaults.
        defaults.set("paused-pdf", forKey: ReaderSessionState.currentlyReadingBookIDKey)
        defaults.set(0, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        player.services.navigation.rememberReaderPlaybackAnchor()
        player.setSnapshot(try JSONDecoder().decode(JobSnapshot.self, from: Data("""
            {"jobId":"paused-pdf","state":"finished","chapterIndexBase":1,"chapterProgress":[
                {"index":1,"status":"completed","downloadUrl":"file:///tmp/paused-pdf.mp3","textOffset":0}]}
            """.utf8)))
        player.services.observation.publishCurrentChapter()
        player.playbackPlayingChanged(true)
        XCTAssertTrue(player.isPlaybackForReaderBook("paused-pdf"))
        let settings = AppSettings(defaults: defaults)
        settings.readerAudioTrackingEnabled = true
        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let pdf = ReaderPDFPresentation(view: view, bookID: "paused-pdf", defaults: defaults,
                                        settings: settings, player: player)
        pdf.load(document: try XCTUnwrap(PDFDocument(url: url)),
                 metadata: try ConverterFFIAdapter().openBook(at: url).metadataJSON)
        view.layoutIfNeeded()
        let item = NSObject()
        for seconds in [1.0, 2.0] {
            player.playbackClock.audioOutput.sample(item: ObjectIdentifier(item), seconds: seconds, isOutputting: true,
                position: .init(chapterIndex: 0, seconds: seconds, duration: 10, sentenceID: nil,
                    itemSeconds: seconds, itemDuration: 10))
        }
        func highlighted() -> [String] { (view.highlightedSelections ?? []).compactMap(\.string) }
        let narrated = highlighted()
        XCTAssertFalse(narrated.isEmpty, "Confirmed output must highlight the narrated passage")

        player.playbackPlayingChanged(false)
        // Longer than the stale-output limit, with several repaint timer ticks.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(highlighted(), narrated, "The paused passage must stay highlighted")

        player.narrationJumps.send()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(highlighted(), [], "After a jump the old passage is no longer where narration resumes")
    }

    /// The spoken text can differ from the page (expanded numbers, rewritten punctuation). As in the EPUB
    /// reader, the sentence then stays marked instead of the highlight disappearing.
    func testPDFHighlightFollowsNarrationWhenTheMeasuredWordIsNotOnThePage() throws {
        let url = try PdfFixture.createMultiPage(pages: [
            (heading: "Narration", body: "A synthetic sentence with 12 lanterns.")])
        defer { try? FileManager.default.removeItem(at: url) }
        let suite = "pdf-unresolved-word-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defaults.set("unresolved-pdf", forKey: ReaderSessionState.currentlyReadingBookIDKey)
        defaults.set(0, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        player.services.navigation.rememberReaderPlaybackAnchor()
        player.setSnapshot(try JSONDecoder().decode(JobSnapshot.self, from: Data("""
            {"jobId":"unresolved-pdf","state":"finished","chapterIndexBase":1,"chapterProgress":[
                {"index":1,"status":"completed","downloadUrl":"file:///tmp/unresolved-pdf.mp3","textOffset":0}]}
            """.utf8)))
        player.services.observation.publishCurrentChapter()
        player.playbackPlayingChanged(true)
        let settings = AppSettings(defaults: defaults)
        settings.readerAudioTrackingEnabled = true
        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let pdf = ReaderPDFPresentation(view: view, bookID: "unresolved-pdf", defaults: defaults,
                                        settings: settings, player: player)
        pdf.load(document: try XCTUnwrap(PDFDocument(url: url)),
                 metadata: try ConverterFFIAdapter().openBook(at: url).metadataJSON)
        view.layoutIfNeeded()
        let measured = try XCTUnwrap(SpeechAudioAlignment(tag: SpeechAudioAlignmentTests.tag(
            #"[{"version":1,"text":"twelve lanterns","audioStart":0,"words":[{"location":0,"length":6,"start":0,"end":9}]}]"#)))
        let item = NSObject()
        for seconds in [1.0, 2.0] {
            player.playbackClock.audioOutput.sample(item: ObjectIdentifier(item), seconds: seconds, isOutputting: true,
                position: .init(chapterIndex: 0, seconds: seconds, duration: 10, sentenceID: nil,
                    itemSeconds: seconds, itemDuration: 10, alignment: measured))
        }
        let highlighted = (view.highlightedSelections ?? []).compactMap(\.string).joined()
        XCTAssertFalse(highlighted.isEmpty, "Narration must stay marked when the measured word cannot be located")
        var alpha: CGFloat = 1
        view.highlightedSelections?.first?.color?.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        XCTAssertLessThan(alpha, 0.5, "A sentence estimate must not look like a measured word")
    }

    func testListeningToAPDFWithATextlessPageTellsOnceThatItWasSkipped() async throws {
        let url = try PdfFixture.createMultiPage(pages: [
            (heading: "", body: ""),
            (heading: "Second page", body: "Second readable passage.")])
        defer { try? FileManager.default.removeItem(at: url) }
        let suite = "pdf-skipped-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = UIViewController()
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        let previousWindow = scene?.windows.first(where: \.isKeyWindow)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = host
        let view = ReaderPDFView(frame: window.bounds)
        host.view.addSubview(view)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        let pdf = ReaderPDFPresentation(view: view, bookID: "fixture", defaults: defaults)
        pdf.load(document: try XCTUnwrap(PDFDocument(url: url)),
                 metadata: try ConverterFFIAdapter().openBook(at: url).metadataJSON)
        view.layoutIfNeeded()
        pdf.goToChapter(0)
        var played = 0
        pdf.onPlayFrom = { _ in played += 1 }
        XCTAssertNil(host.presentedViewController, "Opening the book alone says nothing")

        pdf.playFromCurrentPosition()
        XCTAssertEqual(played, 1, "The notice must not hold back playback")
        try await Task.sleep(nanoseconds: 800_000_000)
        let alert = try XCTUnwrap(host.presentedViewController as? UIAlertController,
                                  "Listening must tell that a page was skipped")
        XCTAssertEqual(alert.message, L10n.string("convert.pdfPagesSkipped.one"))
        let screenshot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        })
        screenshot.name = "ios-pdf-skipped-pages-notice"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        await withCheckedContinuation { done in host.dismiss(animated: false) { done.resume() } }

        pdf.playFromCurrentPosition()
        XCTAssertEqual(played, 2)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertNil(host.presentedViewController, "The notice appears once per opened book")
    }

    func testPDFLayoutSwitchPageNavigationAndReopenPreserveTheSourcePage() throws {
        let url = try PdfFixture.createMultiPage(pages: [
            (heading: "First", body: "First page with readable text."),
            (heading: "Second", body: "Second page with readable text."),
            (heading: "Third", body: "Third page with readable text.")])
        defer { try? FileManager.default.removeItem(at: url) }
        let suite = "pdf-parity-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.readerLayout = .paginated
        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let pdf = ReaderPDFPresentation(view: view, bookID: "fixture", defaults: defaults, settings: settings)
        let document = try XCTUnwrap(PDFDocument(url: url))
        pdf.load(document: document, metadata: try ConverterFFIAdapter().openBook(at: url).metadataJSON)
        view.layoutIfNeeded()
        XCTAssertTrue(view.isUsingPageViewController)
        XCTAssertEqual(view.displayDirection, .horizontal)
        pdf.goToChapter(1)
        XCTAssertEqual(pdf.currentPage, 1)
        var played: PDFReadingAudioMap.Anchor?
        pdf.onPlayFrom = { played = $0 }
        pdf.playFromCurrentPosition()
        XCTAssertEqual(played?.chapterIndex, 1)
        pdf.applyLayout(.scrolling)
        view.layoutIfNeeded()
        XCTAssertFalse(view.isUsingPageViewController)
        XCTAssertEqual(view.displayDirection, .vertical)
        XCTAssertEqual(pdf.currentPage, 1)
        let originalOffset = try XCTUnwrap(pdf.documentOffset)
        pdf.prepareForViewportTransition()
        view.frame.size.height -= 80
        view.layoutIfNeeded()
        pdf.completeViewportTransition()
        XCTAssertEqual(pdf.documentOffset, originalOffset)
        XCTAssertEqual(pdf.currentPage, 1)
        pdf.persistPosition()
        let savedData = try XCTUnwrap(defaults.data(forKey: "reader.pdf.position.v1.fixture"))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: savedData) as? [String: Any])
        XCTAssertEqual(saved["page"] as? Int, 1)
        let reopenedView = ReaderPDFView(frame: view.frame)
        let reopened = ReaderPDFPresentation(view: reopenedView, bookID: "fixture", defaults: defaults, settings: settings)
        reopened.load(document: PDFDocument(url: url), metadata: nil)
        reopenedView.layoutIfNeeded()
        XCTAssertEqual(reopened.currentPage, 1)
        let other = ReaderPDFPresentation(view: ReaderPDFView(frame: view.frame), bookID: "other", defaults: defaults)
        other.load(document: PDFDocument(url: url), metadata: nil)
        XCTAssertEqual(other.currentPage, 0)
    }

    func testAppLongPressRemainsOnTheContainingSurfaceAcrossPDFLayoutAndRemoval() throws {
        let source = try PdfFixture.createSinglePage(bodyText: "A selectable PDF passage.")
        defer { try? FileManager.default.removeItem(at: source) }
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let view = ReaderPDFView(frame: container.bounds)
        container.addSubview(view)
        let press = try XCTUnwrap(container.gestureRecognizers?.compactMap { $0 as? UILongPressGestureRecognizer }.first)
        view.document = PDFDocument(url: source)
        view.layoutIfNeeded()
        XCTAssertTrue(press.isEnabled)
        XCTAssertTrue(press.view === container)
        XCTAssertFalse(press.delegate === view, "App gestures must not dispatch through PDFKit's optional delegate methods")
        XCTAssertTrue(press.delegate?.gestureRecognizerShouldBegin?(press) == true)
        view.removeFromSuperview()
        XCTAssertNil(press.view, "Closing/replacing the PDF must remove its app interaction from the old surface")
    }

    func testTextTapOffersPlaybackAtTheTappedGlyphAndToolbarUsesTheVisiblePage() throws {
        let source = try PdfFixture.createMultiPage(pages: [
            (heading: "First", body: "Earlier narration."),
            (heading: "Second", body: "The later selectable passage has a distinct playback offset.")
        ])
        defer { try? FileManager.default.removeItem(at: source) }
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        let id = "text-pdf-playback-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        defer { defaults.removePersistentDomain(forName: id) }
        let settings = AppSettings(defaults: defaults)
        settings.readerLayout = .paginated
        let view = ReaderPDFView(frame: host.view.bounds)
        host.view.addSubview(view)
        let pdf = ReaderPDFPresentation(view: view, bookID: "fixture", defaults: defaults, settings: settings)
        let document = try XCTUnwrap(PDFDocument(url: source))
        pdf.load(document: document, metadata: try ConverterFFIAdapter().openBook(at: source).metadataJSON)
        view.layoutIfNeeded()
        pdf.goToChapter(1)
        view.layoutIfNeeded()
        let page = try XCTUnwrap(document.page(at: 1))
        let text = try XCTUnwrap(page.string) as NSString
        let range = text.range(of: "selectable")
        guard range.location != NSNotFound else { return XCTFail("The fixture must contain selectable text") }
        let glyph = page.characterBounds(at: range.location)
        let point = view.convert(CGPoint(x: glyph.midX, y: glyph.midY), from: page)
        let anchor = try XCTUnwrap(pdf.anchor(at: point))
        XCTAssertEqual(anchor.chapterIndex, 1)
        XCTAssertGreaterThan(anchor.ratio, 0)

        var chromeToggles = 0
        pdf.onToggleChrome = { chromeToggles += 1 }
        let tap = try XCTUnwrap(view.onReaderTap)
        tap(point)
        let sheet = try XCTUnwrap(host.presentedViewController as? UIAlertController)
        XCTAssertEqual(sheet.preferredStyle, .actionSheet)
        XCTAssertTrue(sheet.actions.first { $0.title == L10n.string("reader.selection.playFromHere") }?.isEnabled == true)
        XCTAssertEqual(chromeToggles, 0)

        var toolbarAnchor: PDFReadingAudioMap.Anchor?
        pdf.onPlayFrom = { toolbarAnchor = $0 }
        pdf.playFromCurrentPosition()
        XCTAssertEqual(toolbarAnchor?.chapterIndex, 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(toolbarAnchor?.ratio), anchor.ratio)
    }

    func testPDFSuppressesSystemEditingMenuButKeepsAppPlayAction() throws {
        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        XCTAssertFalse(view.canBecomeFirstResponder)
        XCTAssertFalse(view.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
        let nativeSelection = UILongPressGestureRecognizer()
        view.addGestureRecognizer(nativeSelection)
        let textSurface = UIView(frame: view.bounds)
        view.addSubview(textSurface)
        let nativeText = UITextInteraction(for: .nonEditable)
        textSurface.addInteraction(nativeText)
        let zoom = UIPinchGestureRecognizer()
        textSurface.addGestureRecognizer(zoom)
        if #available(iOS 16.0, *) {
            textSurface.addInteraction(UIEditMenuInteraction(delegate: nil))
        }
        view.layoutIfNeeded()
        XCTAssertFalse(nativeSelection.isEnabled)
        XCTAssertNil(nativeText.view)
        XCTAssertFalse(textSurface.interactions.contains { $0 is UITextInteraction || $0 is UIContextMenuInteraction })
        if #available(iOS 16.0, *) {
            XCTAssertFalse(textSurface.interactions.contains { $0 is UIEditMenuInteraction })
        }
        XCTAssertTrue(zoom.isEnabled, "Suppressing editing must preserve PDF navigation gestures")
        let menuDelegate = PDFEditingMenuDelegate()
        let lateContextMenu = UIContextMenuInteraction(delegate: menuDelegate)
        textSurface.addInteraction(lateContextMenu)
        textSurface.addInteraction(nativeText)
        view.prepareForReaderInteraction()
        XCTAssertNil(lateContextMenu.view, "Page turns can install another editing menu after layout")
        XCTAssertNil(nativeText.view)
        XCTAssertTrue(view.gestureRecognizers?.contains { $0 is UILongPressGestureRecognizer && $0.isEnabled } == true)
        let suite = "pdf-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = ReaderSettingsScreenController(settings: AppSettings(defaults: defaults), isPDF: true)
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.tableView(controller.tableView, numberOfRowsInSection: 1), 0)
        XCTAssertEqual(controller.tableView(controller.tableView, numberOfRowsInSection: 2), 2)
    }
}

private final class PDFEditingMenuDelegate: NSObject, UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? { nil }
}
#endif
