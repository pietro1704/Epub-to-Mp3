#if os(macOS)
import AppKit
import PDFKit
import XCTest
@testable import EpubToMp3

/// READER-FOLLOW-NARRATION-MAC on the real AppKit reader surfaces: the viewport follows the narration forward and
/// backward, a manual scroll or page change stops it, and an explicit narration action (seek) resumes it.
@MainActor
final class MacReaderNarrationFollowingTests: XCTestCase {
    private let defaultsKeys = [ReaderSessionState.currentlyReadingBookIDKey, AudioPlayer.readerCurrentChapterIndexDefaultsKey]
    private var savedDefaults: [Any?] = []

    override func setUp() {
        savedDefaults = defaultsKeys.map { UserDefaults.standard.object(forKey: $0) }
    }

    override func tearDown() {
        for (key, value) in zip(defaultsKeys, savedDefaults) { UserDefaults.standard.set(value, forKey: key) }
    }

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

    private func eventually(timeout: Int = 80, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<timeout {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    /// What `NSApp.currentEvent` would say: tests flip it around the moves a person would make.
    private final class UserInput { var active = false }

    @MainActor private struct TextRig {
        let harness: NativeReaderTestHarness
        let following: MacReaderNarrationFollowing
        let input: UserInput
        var clip: NSClipView { harness.composition.contentScrollView.contentView }
        var offset: CGFloat { clip.bounds.origin.y }
        func manualScroll(to y: CGFloat) {
            input.active = true
            defer { input.active = false }
            clip.scroll(to: NSPoint(x: 0, y: y))
            harness.composition.contentScrollView.reflectScrolledClipView(clip)
        }
    }

    private func makeTextRig() throws -> TextRig {
        let chapters: [EbookFulltext.Chapter] = (1...3).map { index in
            NativeReaderTestHarness.chapter("Chapter \(index).\n\n" + String(repeating:
                "Travellers crossed the quiet valley and followed the winding river through the forest.\n\n", count: 90),
                index: index, name: "Chapter \(index)")
        }
        let harness = try NativeReaderTestHarness(chapters: chapters)
        harness.installTeardown(in: self)
        harness.document.hasRestoredInitialPosition = true
        harness.controller.view.layoutSubtreeIfNeeded()
        harness.showChapter(0)
        harness.controller.view.layoutSubtreeIfNeeded()
        let input = UserInput()
        let following = MacReaderNarrationFollowing(
            document: harness.document, composition: harness.composition, player: harness.player,
            settings: harness.settings, showChapterIndex: { [harness] in harness.showChapter($0) },
            isUserInput: { input.active })
        following.observe()
        addTeardownBlock { @MainActor in following.stop() }
        return TextRig(harness: harness, following: following, input: input)
    }

    private final class OutputItem {}

    /// Two advancing samples: the first only arms the cursor, the second confirms audible output.
    private func output(_ player: AudioPlayer, item: OutputItem, at seconds: TimeInterval) {
        for time in [seconds, seconds + 0.1] {
            player.playbackClock.audioOutput.sample(item: ObjectIdentifier(item), seconds: time, isOutputting: true,
                position: .init(chapterIndex: 0, seconds: time, duration: 3_000, sentenceID: nil,
                                itemSeconds: time, itemDuration: 3_000))
        }
    }

    /// MAC-NARRATION-HIGHLIGHT: the follow-audio setting had no effect because the Mac reader never highlighted.
    func testTextReaderHighlightsTheNarratedSentenceOnlyWhileFollowAudioIsEnabled() async throws {
        let rig = try makeTextRig()
        let player = rig.harness.player, settings = rig.harness.settings
        let savedTracking = settings.readerAudioTrackingEnabled
        addTeardownBlock { @MainActor in settings.readerAudioTrackingEnabled = savedTracking }
        settings.readerAudioTrackingEnabled = true
        let text = rig.harness.composition.textView
        let manager = try XCTUnwrap(text.layoutManager)
        func isHighlighted(_ location: Int) -> Bool {
            manager.temporaryAttribute(.backgroundColor, atCharacterIndex: location, effectiveRange: nil) != nil
        }
        let item = OutputItem()
        try narrate(player, bookID: rig.harness.id, textOffset: 0)
        var time = 0.1
        let highlighted = await eventually {
            time += 0.2
            output(player, item: item, at: time)
            return isHighlighted(0)
        }
        XCTAssertTrue(highlighted, "The sentence being narrated must be highlighted")
        XCTAssertFalse(isHighlighted(text.string.utf16.count - 3), "Only the narrated passage is highlighted")

        settings.readerAudioTrackingEnabled = false
        let cleared = await eventually {
            time += 0.2
            output(player, item: item, at: time)
            return !isHighlighted(0)
        }
        XCTAssertTrue(cleared, "Turning follow audio off must remove the highlight")
        try await Task.sleep(nanoseconds: 300_000_000)
        output(player, item: item, at: time + 0.2)
        XCTAssertFalse(isHighlighted(0), "No highlight may come back while follow audio is off")

        settings.readerAudioTrackingEnabled = true
        let restored = await eventually {
            time += 0.2
            output(player, item: item, at: time + 0.2)
            return isHighlighted(0)
        }
        XCTAssertTrue(restored)

        rig.following.stop()
        XCTAssertFalse(isHighlighted(0), "Closing the reader must leave no highlight behind")
    }

    /// Pausing keeps the passage marked so the reader shows where narration resumes; a seek drops the old mark.
    func testTextReaderKeepsTheHighlightWhilePausedUntilTheNarrationMoves() async throws {
        let rig = try makeTextRig()
        let player = rig.harness.player, settings = rig.harness.settings
        let savedTracking = settings.readerAudioTrackingEnabled
        addTeardownBlock { @MainActor in settings.readerAudioTrackingEnabled = savedTracking }
        settings.readerAudioTrackingEnabled = true
        let manager = try XCTUnwrap(rig.harness.composition.textView.layoutManager)
        func isHighlighted() -> Bool {
            manager.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil) != nil
        }
        let item = OutputItem()
        try narrate(player, bookID: rig.harness.id, textOffset: 0)
        var time = 0.1
        let highlighted = await eventually {
            time += 0.2
            output(player, item: item, at: time)
            return isHighlighted()
        }
        XCTAssertTrue(highlighted)

        player.pause()
        XCTAssertFalse(player.isPlaying)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertTrue(isHighlighted(), "The paused passage must stay highlighted")

        settings.readerAudioTrackingEnabled = false
        XCTAssertFalse(isHighlighted(), "Turning follow audio off must remove the held highlight")
        settings.readerAudioTrackingEnabled = true

        player.seek(to: 2_000)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(isHighlighted(), "After a seek the old passage is no longer where narration resumes")
    }

    func testTextViewportFollowsTheNarrationForwardAndBackward() async throws {
        let rig = try makeTextRig()
        let player = rig.harness.player, id = rig.harness.id
        try narrate(player, bookID: id, textOffset: 0)
        let paired = await eventually { player.readerPairing.isPaired }
        XCTAssertTrue(paired)
        XCTAssertEqual(rig.offset, 0, accuracy: 0.5)

        try narrate(player, bookID: id, textOffset: 6_000)
        let forward = await eventually { rig.offset > 0 && player.readerPairing.isPaired }
        XCTAssertTrue(forward, "The viewport must move to the narrated passage by itself")

        try narrate(player, bookID: id, textOffset: 0)
        let backward = await eventually { rig.offset < 1 && player.readerPairing.isPaired }
        XCTAssertTrue(backward, "Seeking back must move the viewport back")
    }

    func testTextReaderFollowsTheNarrationIntoAnotherChapter() async throws {
        let rig = try makeTextRig()
        try narrate(rig.harness.player, bookID: rig.harness.id, textOffset: 0)
        try narrate(rig.harness.player, bookID: rig.harness.id, chapter: 2, textOffset: 100)
        let moved = await eventually { rig.harness.document.selectedChapter == 1 }
        XCTAssertTrue(moved, "A chapter change in the narration must bring the reader to that chapter")
        XCTAssertTrue(rig.harness.composition.textView.string.hasPrefix("Chapter 2."))
    }

    /// REMOTE-JUMP parity: with auto-scroll off the page stays put, even after a seek; "Go to reading" still works.
    func testTextReaderStaysPutWhileAutoScrollIsOff() async throws {
        let rig = try makeTextRig()
        let player = rig.harness.player, id = rig.harness.id, settings = rig.harness.settings
        let saved = settings.readerAutoScroll
        addTeardownBlock { @MainActor in settings.readerAutoScroll = saved }
        settings.readerAutoScroll = false
        try narrate(player, bookID: id, textOffset: 6_000)
        player.seek(to: 1)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(rig.offset, 0, accuracy: 0.5, "Auto-scroll is off: the reader must not move by itself")

        rig.following.goToNarration()
        let asked = await eventually { rig.offset > 0 }
        XCTAssertTrue(asked, "An explicit Go to reading still shows the spoken passage")

        settings.readerAutoScroll = true
        try narrate(player, bookID: id, textOffset: 0)
        let followed = await eventually { rig.offset < 1 }
        XCTAssertTrue(followed, "Turning auto-scroll back on resumes following")
    }

    func testTextReaderStopsFollowingAfterAManualScrollAndResumesOnNarrationActions() async throws {
        let rig = try makeTextRig()
        let player = rig.harness.player, id = rig.harness.id
        try narrate(player, bookID: id, textOffset: 0)
        _ = await eventually { player.readerPairing.isPaired }

        rig.manualScroll(to: 1_000)
        let manual = rig.offset
        XCTAssertGreaterThan(manual, 0)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(rig.offset, manual, accuracy: 0.5, "A manual scroll must not be undone by following")
        XCTAssertTrue(rig.following.isSuspended)
        XCTAssertFalse(player.readerPairing.isPaired)

        player.seek(to: 1)
        let resumed = await eventually { rig.offset < 1 && player.readerPairing.isPaired }
        XCTAssertTrue(resumed, "A seek must make the reader follow again")

        rig.manualScroll(to: 1_000)
        rig.manualScroll(to: 0)
        XCTAssertTrue(player.readerPairing.isPaired)
        try narrate(player, bookID: id, textOffset: 6_000)
        let byPairing = await eventually { rig.offset > 0 && player.readerPairing.isPaired }
        XCTAssertTrue(byPairing, "Scrolling back to the narrated passage resumes following")
    }

    func testPDFViewFollowsTheNarrationAndStopsAfterAManualPageChange() async throws {
        let harness = try NativeReaderTestHarness(chapters: [])
        harness.installTeardown(in: self)
        harness.document.hasRestoredInitialPosition = true
        let source = try PdfFixture.createMultiPage(pages: [
            (heading: "First page", body: "First readable passage for narration."),
            (heading: "Second page", body: "Second readable passage for narration."),
            (heading: "Third page", body: "Third readable passage for narration.")])
        defer { try? FileManager.default.removeItem(at: source) }
        harness.controller.view.layoutSubtreeIfNeeded()
        _ = await harness.text.showPDF(source)
        let pdf = try XCTUnwrap(harness.composition.contentScrollView.documentView as? MacReaderPDFView)
        // One page at a time, so "visible" means the narrated page and nothing else (continuous mode shows two).
        pdf.displayMode = .singlePage
        pdf.layoutDocumentView()
        XCTAssertEqual(pdf.audioMap?.chapters.count, 3, "The Rust narration axis must map the PDF pages")
        let input = UserInput()
        let following = MacReaderNarrationFollowing(
            document: harness.document, composition: harness.composition, player: harness.player,
            settings: harness.settings, showChapterIndex: { _ in }, isUserInput: { input.active })
        following.observe()
        addTeardownBlock { @MainActor in following.stop() }
        let document = try XCTUnwrap(pdf.document)
        func page() -> Int? { pdf.currentPage.map { document.index(for: $0) } }
        let player = harness.player

        try narrate(player, bookID: harness.id, chapter: 3, textOffset: 0)
        let forward = await eventually { page() == 2 }
        try narrate(player, bookID: harness.id, chapter: 1, textOffset: 0)
        let backward = await eventually { page() == 0 }
        XCTAssertTrue(backward, "Seeking back must move the PDF back")

        input.active = true
        pdf.go(to: try XCTUnwrap(document.page(at: 1)))
        try await Task.sleep(nanoseconds: 300_000_000)
        input.active = false
        try narrate(player, bookID: harness.id, chapter: 3, textOffset: 0)
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(page(), 1, "A manual page change must not be undone by following")

        player.seek(to: 1)
        let resumed = await eventually { page() == 2 }
        XCTAssertTrue(resumed)
    }

    func testOnlyUserInputEventsCountAsManualMoves() throws {
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            switch type {
            case .keyDown:
                return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                        context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)
            case .leftMouseUp:
                return NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
            default:
                return NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)
            }
        }
        XCTAssertTrue(MacReaderNarrationFollowing.isUserInput(event(.keyDown)))
        XCTAssertTrue(MacReaderNarrationFollowing.isUserInput(event(.leftMouseUp)))
        XCTAssertFalse(MacReaderNarrationFollowing.isUserInput(event(.applicationDefined)),
                       "Application-defined events (layout, timers) are not the user")
        XCTAssertFalse(MacReaderNarrationFollowing.isUserInput(nil), "No current event: PDFKit or layout moved the viewport")
    }
}
#endif