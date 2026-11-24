#if os(iOS)
import PDFKit
import UIKit
import XCTest
@testable import EpubToMp3

/// READER-FOLLOW-NARRATION on the real readers: the page turns by itself while the narration advances (forward and
/// backward), a manual page turn stops it, and an explicit narration action resumes it. EPUB/TXT and PDF.
@MainActor
final class ReaderFollowNarrationReaderTests: XCTestCase {
    private let defaultsKeys = [ReaderSessionState.currentlyReadingBookIDKey, AudioPlayer.readerCurrentChapterIndexDefaultsKey]
    private var savedDefaults: [Any?] = []

    override func setUp() {
        savedDefaults = defaultsKeys.map { UserDefaults.standard.object(forKey: $0) }
    }

    override func tearDown() {
        for (key, value) in zip(defaultsKeys, savedDefaults) { UserDefaults.standard.set(value, forKey: key) }
    }

    /// The narration of `bookID` is playing at `textOffset` of the one-based `chapter`.
    private func narrate(_ player: AudioPlayer, bookID: String, chapter: Int = 1, textOffset: Int) throws {
        UserDefaults.standard.set(bookID, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        UserDefaults.standard.set(chapter - 1, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        player.services.navigation.rememberReaderPlaybackAnchor()
        let snapshot = try JSONDecoder().decode(JobSnapshot.self, from: Data("""
            {"jobId":"\(bookID)","state":"finished","chapterIndexBase":1,"chapterProgress":[
                {"index":\(chapter),"status":"completed","downloadUrl":"file:///tmp/follow.mp3","textOffset":\(textOffset)}]}
            """.utf8))
        player.setSnapshot(snapshot)
        player.services.observation.publishCurrentChapter()
        player.playbackPlayingChanged(true)
    }

    private func eventually(_ description: String, timeout: Int = 80, _ condition: () throws -> Bool,
                      settle: () async -> Void) async rethrows -> Bool {
        for _ in 0..<timeout {
            await settle()
            if try condition() { return true }
        }
        return false
    }

    // MARK: EPUB / TXT

    func testTextReaderTurnsThePageWithTheNarrationForwardAndBackward() async throws {
        let fixture = try PositionFixture(hasAudio: true)
        defer { fixture.cleanUp() }
        try await fixture.open()
        try narrate(fixture.player, bookID: fixture.id, textOffset: 0)
        let pairedAtStart = await eventually("paired at the start", { fixture.player.readerPairing.isPaired }, settle: fixture.settle)
        XCTAssertTrue(pairedAtStart)
        XCTAssertEqual(try fixture.offset(), 0, accuracy: 0.5)

        try narrate(fixture.player, bookID: fixture.id, textOffset: 6_000)
        let followedForward = try await eventually("forward", { try fixture.offset() > 0 && fixture.player.readerPairing.isPaired },
                                             settle: fixture.settle)
        XCTAssertTrue(followedForward, "The page must turn by itself when the narration leaves it")

        try narrate(fixture.player, bookID: fixture.id, textOffset: 0)
        let followedBackward = try await eventually("backward", { try fixture.offset() < 1 && fixture.player.readerPairing.isPaired },
                                              settle: fixture.settle)
        XCTAssertTrue(followedBackward, "Seeking back must turn the page back")
    }

    func testTextReaderFollowsTheNarrationIntoAnotherChapter() async throws {
        let fixture = try PositionFixture(hasAudio: true)
        defer { fixture.cleanUp() }
        try await fixture.open()
        try narrate(fixture.player, bookID: fixture.id, textOffset: 0)
        try narrate(fixture.player, bookID: fixture.id, chapter: 2, textOffset: 100)
        let reader = try XCTUnwrap(fixture.controller)
        let moved = await eventually("chapter 2", { reader.currentReaderChapterIndex == 1 }, settle: fixture.settle)
        XCTAssertTrue(moved, "A chapter change in the narration must bring the reader to that chapter")
        XCTAssertTrue(fixture.textView()?.text.hasPrefix("Chapter 2.") == true)
    }

    func testTextReaderStopsFollowingAfterAManualTurnAndResumesOnNarrationActions() async throws {
        let fixture = try PositionFixture(hasAudio: true)
        defer { fixture.cleanUp() }
        try await fixture.open()
        try narrate(fixture.player, bookID: fixture.id, textOffset: 0)
        _ = await eventually("paired", { fixture.player.readerPairing.isPaired }, settle: fixture.settle)

        try await fixture.turn(forward: true)
        let manualOffset = try fixture.offset()
        XCTAssertGreaterThan(manualOffset, 0)
        for _ in 0..<15 { await fixture.settle() }
        XCTAssertEqual(try fixture.offset(), manualOffset, accuracy: 0.5, "A manual turn must not be undone by following")
        XCTAssertFalse(fixture.player.readerPairing.isPaired)

        // An explicit action on the narration (seek) makes the reader follow again.
        fixture.player.seek(to: 1)
        let resumedBySeek = try await eventually("resume by seek", { try fixture.offset() < 1 && fixture.player.readerPairing.isPaired },
                                           settle: fixture.settle)
        XCTAssertTrue(resumedBySeek)

        // Turning back by hand to the narrated page also resumes it (the page holds the passage again).
        try await fixture.turn(forward: true)
        try await fixture.turn(forward: false)
        XCTAssertTrue(fixture.player.readerPairing.isPaired)
        try narrate(fixture.player, bookID: fixture.id, textOffset: 6_000)
        let resumedByPairing = try await eventually("resume by pairing", { try fixture.offset() > 0 && fixture.player.readerPairing.isPaired },
                                              settle: fixture.settle)
        XCTAssertTrue(resumedByPairing)
    }

    // MARK: PDF

    @MainActor private struct PDFRig {
        let view: ReaderPDFView
        let pdf: ReaderPDFPresentation
        let window: UIWindow
        let player: AudioPlayer
        let defaults: UserDefaults
        let suite: String
        let text: String
        let pageStarts: [Int]
        let previousWindow: UIWindow?

        func teardown() {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
            player.stop()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func makePDFRig(bookID: String) throws -> (PDFRig, URL) {
        let url = try PdfFixture.createMultiPage(pages: [
            (heading: "First", body: "First page of the book with readable text for narration."),
            (heading: "Second", body: "Second page of the book with readable text for narration."),
            (heading: "Third", body: "Third page of the book with readable text for narration.")])
        let document = try XCTUnwrap(PDFDocument(url: url))
        let pages = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        var text = ""
        var starts: [Int] = []
        for page in pages {
            starts.append((text as NSString).length)
            text += page + "\n\n"
        }
        let metadata = try JSONSerialization.data(withJSONObject: ["chapters": [
            ["index": "1", "name": "One chapter", "sourcePath": "page-1", "text": text]]])
        let suite = "pdf-follow-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        settings.readerLayout = .paginated
        let player = AudioPlayer()
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
        let pdf = ReaderPDFPresentation(view: view, bookID: bookID, defaults: defaults, settings: settings, player: player)
        pdf.load(document: document, metadata: metadata)
        view.layoutIfNeeded()
        return (PDFRig(view: view, pdf: pdf, window: window, player: player, defaults: defaults, suite: suite,
                       text: text, pageStarts: starts, previousWindow: previousWindow), url)
    }

    private func settlePDF(_ rig: PDFRig) async {
        rig.view.layoutIfNeeded()
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func testPDFReaderFollowsTheNarrationForwardBackwardAndStopsAfterAManualTurn() async throws {
        let bookID = "pdf-follow-\(UUID().uuidString)"
        let (rig, url) = try makePDFRig(bookID: bookID)
        defer { rig.teardown(); try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(rig.pdf.currentPage, 0)
        let thirdPage = rig.pageStarts[2] + 4

        try narrate(rig.player, bookID: bookID, textOffset: thirdPage)
        let forward = await eventually("pdf forward", { rig.pdf.currentPage == 2 }, settle: { await self.settlePDF(rig) })
        XCTAssertTrue(forward, "The PDF must turn to the narrated page by itself")

        try narrate(rig.player, bookID: bookID, textOffset: 2)
        let backward = await eventually("pdf backward", { rig.pdf.currentPage == 0 }, settle: { await self.settlePDF(rig) })
        XCTAssertTrue(backward, "Seeking back must turn the PDF back")

        // Manual turn away from the narrated page: following stops.
        rig.pdf.turnPage(forward: true)
        for _ in 0..<5 { await settlePDF(rig) }
        let manualPage = try XCTUnwrap(rig.pdf.currentPage)
        XCTAssertEqual(manualPage, 1)
        try narrate(rig.player, bookID: bookID, textOffset: thirdPage)
        for _ in 0..<15 { await settlePDF(rig) }
        XCTAssertEqual(rig.pdf.currentPage, 1, "A manual page turn must not be undone by following")

        // An explicit narration action resumes it.
        rig.player.seek(to: 1)
        let resumed = await eventually("pdf resume", { rig.pdf.currentPage == 2 }, settle: { await self.settlePDF(rig) })
        XCTAssertTrue(resumed)
    }
}
#endif
