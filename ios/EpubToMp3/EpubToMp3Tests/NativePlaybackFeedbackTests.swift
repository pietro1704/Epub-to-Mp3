#if os(iOS)
import AVFoundation
import UIKit
import XCTest
#if canImport(ActivityKit)
import ActivityKit
#endif
@testable import EpubToMp3

@MainActor
final class NativePlaybackFeedbackTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suite = "playback-feedback-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    func testBothMenusIncludeNormalSpeedAndMarkExactlyTheActiveRateIncludingLegacyValues() async throws {
        let defaults = try defaults()
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let library = LibraryStore(defaults: defaults)
        let full = FullPlayerScreenController(player: player, playbackClock: player.playbackClock,
            library: library, playerPresentation: PlayerPresentation(defaults: defaults),
            settings: AppSettings(defaults: defaults), onStartListening: {})
        full.loadViewIfNeeded()
        let mini = MiniPlayerBarUIKitView()
        mini.configure(player: player, playbackClock: player.playbackClock, library: library, onTap: {})
        let fullButton = try XCTUnwrap(descendants(full.view).compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "fullPlayer.playbackRateButton" })
        let miniButton = try XCTUnwrap(descendants(mini).compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "miniPlayer.rate" })
        for rate in [PlaybackRate.x100, .x150, .x080, .x100] {
            player.setRate(rate)
            try await Task.sleep(nanoseconds: 30_000_000)
            mini.refresh()
            for button in [fullButton, miniButton] {
                let menu = try XCTUnwrap(button.menu)
                let actions = menu.children.compactMap { $0 as? UIAction }
                XCTAssertEqual(actions.filter { $0.title == "1x" }.count, 1)
                XCTAssertEqual(actions.filter { $0.state == .on }.map(\.title), [rate.shortLabel])
                XCTAssertTrue(menu.options.contains(.singleSelection))
            }
        }
        XCTAssertFalse(player.isPlaying, "Changing speed must not grant autoplay")
    }

    func testExpandedPanelStartsAtRootSafeAreaInBothOrientations() async throws {
        let defaults = try defaults()
        let presentation = PlayerPresentation(defaults: defaults)
        let root = IOSRootContainerController(settings: AppSettings(defaults: defaults),
            library: LibraryStore(defaults: defaults), player: AudioPlayer(),
            playerPresentation: presentation, bookmarkStore: BookmarkStore(defaults: defaults))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        root.additionalSafeAreaInsets.top = 24
        presentation.showFullPlayer()
        try await Task.sleep(nanoseconds: 30_000_000)
        root.view.layoutIfNeeded()
        let full = try XCTUnwrap(root.children.compactMap { $0 as? FullPlayerScreenController }.first)
        for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390)] {
            window.frame.size = size
            root.view.frame = window.bounds
            root.view.layoutIfNeeded()
            XCTAssertEqual(full.view.frame.minY, root.view.safeAreaLayoutGuide.layoutFrame.minY, accuracy: 0.5)
            let handle = try XCTUnwrap(descendants(full.view).first { $0.accessibilityIdentifier == "fullPlayer.dragHandle" })
            XCTAssertGreaterThanOrEqual(handle.convert(handle.bounds, to: root.view).minY, full.view.frame.minY)
        }
    }

    func testOutputRequiresAdvancingCurrentItemAndClearsForWaitingSeekReplacementAndStaleTicks() async throws {
        let output = PlaybackAudioOutput()
        let first = NSObject(), replacement = NSObject()
        func sample(_ item: NSObject, _ seconds: Double, playing: Bool = true) {
            output.sample(item: ObjectIdentifier(item), seconds: seconds, isOutputting: playing,
                position: .init(chapterIndex: 7, seconds: seconds, duration: 30,
                    sentenceID: nil, itemSeconds: seconds, itemDuration: 30))
        }
        sample(first, 4)
        XCTAssertNil(output.position, "A playing status and an old cursor do not prove output")
        sample(first, 4.25)
        XCTAssertEqual(output.position?.chapterIndex, 7)
        sample(first, 4.25)
        XCTAssertNil(output.position, "A stalled cursor must clear immediately")
        sample(first, 4.5)
        XCTAssertNotNil(output.position)
        sample(first, 4.75, playing: false)
        XCTAssertNil(output.position)
        sample(first, 8)
        XCTAssertNil(output.position)
        sample(first, 8.25)
        XCTAssertNotNil(output.position)
        sample(replacement, 8.5)
        XCTAssertNil(output.position, "An old item's progress cannot establish output for a new item")
        sample(replacement, 8.75)
        output.clear()
        XCTAssertNil(output.position)
        sample(replacement, 9)
        XCTAssertNil(output.position, "Seeking must establish a fresh baseline")
        sample(replacement, 9.25)
        XCTAssertNotNil(output.position)
        try await Task.sleep(nanoseconds: 950_000_000)
        XCTAssertNil(output.position, "Missing periodic callbacks cannot leave a permanent highlight")
    }

    func testReaderHighlightPreservesAnnotationsAndOffsetAndRejectsAnotherChapterOrBook() throws {
        let defaults = try defaults()
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey, AudioPlayer.readerCurrentChapterIndexDefaultsKey]
        let saved = keys.map { standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) } }
        standard.set("highlight-fixture", forKey: keys[0])
        standard.set(0, forKey: keys[1])
        player.rememberReaderPlaybackAnchor()
        player.playbackPlayingChanged(true)
        let document = ReaderBookDocument(book: BookEntity(id: "highlight-fixture", title: "Fixture",
            bookmark: Data(), displayFilename: "fixture.epub", addedAt: Date(), fileType: .epub))
        let chapter = EbookFulltext.Chapter(index: 1, name: "Chapter", text: "Olá 👋 mundo mundo.",
            html: nil, css: nil, charCount: nil, segments: nil)
        document.fulltext = EbookFulltext(jobId: "highlight-fixture", bookTitle: nil, bookAuthor: nil, chapters: [chapter])
        let textView = ReaderTextViewFactory.make()
        textView.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        let manager = try XCTUnwrap(textView.layoutManager as? ReaderPlaybackLayoutManager)
        let content = NSAttributedString(string: chapter.text, attributes: [.backgroundColor: UIColor.systemPink])
        textView.attributedText = content
        textView.contentOffset = CGPoint(x: 0, y: 12)
        let settings = AppSettings(defaults: defaults)
        let paint = ReaderAudioHighlightPresentation(document: document, player: player, textView: textView, settings: settings)
        paint.observe()
        let item = NSObject()
        let measured = try XCTUnwrap(SpeechAudioAlignment(tag: SpeechAudioAlignmentTests.tag(
            #"[{"version":1,"text":"Olá 👋 mundo mundo.","audioStart":0,"sourceOffset":0,"words":[{"location":13,"length":5,"start":1.5,"end":2.5}]}]"#)))
        func sample(_ seconds: Double, chapter: Int = 0, hasMeasuredAlignment: Bool = true) {
            player.playbackClock.audioOutput.sample(item: ObjectIdentifier(item), seconds: seconds, isOutputting: true,
                position: .init(chapterIndex: chapter, seconds: seconds, duration: 10, sentenceID: nil,
                    itemSeconds: seconds, itemDuration: 10, alignment: hasMeasuredAlignment ? measured : nil))
        }
        func backgroundImage() -> Data? {
            manager.ensureLayout(for: textView.textContainer)
            return UIGraphicsImageRenderer(bounds: textView.bounds).image { _ in
                manager.drawBackground(forGlyphRange: manager.glyphRange(for: textView.textContainer), at: .zero)
            }.pngData()
        }
        let backgroundBefore = backgroundImage()
        // UIKit fixes default/fallback fonts during its first layout. Compare
        // painting with that committed TextKit baseline, including emoji fonts.
        let normalizedContent = NSAttributedString(attributedString: textView.attributedText)
        let offset = textView.contentOffset
        sample(1)
        sample(2)
        XCTAssertNotEqual(backgroundImage(), backgroundBefore, "Confirmed output must paint a visible background")
        XCTAssertNotNil(manager.activeSentenceRange)
        XCTAssertEqual(manager.activeWordRange, NSRange(location: 13, length: 5),
                       "The measured second occurrence wins over proportional character estimates")
        let renderedWord = UIGraphicsImageRenderer(size: textView.bounds.size).image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: textView.bounds.size))
            let glyphs = manager.glyphRange(for: textView.textContainer)
            let origin = CGPoint(x: textView.textContainerInset.left, y: textView.textContainerInset.top)
            manager.drawBackground(forGlyphRange: glyphs, at: origin)
            manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        }
        let measuredImage = XCTAttachment(image: renderedWord)
        measuredImage.name = "measured-repeated-word-native-textkit"
        measuredImage.lifetime = .keepAlways
        add(measuredImage)
        XCTAssertEqual(textView.attributedText, normalizedContent)
        XCTAssertEqual(textView.contentOffset, offset)
        sample(2.1, hasMeasuredAlignment: false)
        XCTAssertNotNil(manager.activeSentenceRange)
        XCTAssertNil(manager.activeWordRange, "Legacy audio must not manufacture a current word from character length")
        sample(2.2)
        XCTAssertEqual(manager.activeWordRange, NSRange(location: 13, length: 5))
        settings.readerAudioTrackingEnabled = false
        XCTAssertNil(manager.activeWordRange, "Disabling tracking clears paint immediately without stopping audio")
        XCTAssertTrue(player.isPlaying)
        sample(2.25)
        XCTAssertNil(manager.activeSentenceRange)
        XCTAssertEqual(textView.attributedText, normalizedContent)
        XCTAssertEqual(textView.contentOffset, offset)
        settings.readerAudioTrackingEnabled = true
        XCTAssertNotNil(manager.activeSentenceRange, "Re-enabling tracking uses the current confirmed output")
        player.playbackClock.audioOutput.clear()
        XCTAssertNil(manager.activeSentenceRange)
        XCTAssertEqual(textView.attributedText, normalizedContent, "Clearing output must retain saved annotation colors")
        sample(3)
        sample(4, chapter: 9)
        XCTAssertNil(manager.activeSentenceRange)
        document.book = BookEntity(id: "other-book", title: "Other", bookmark: Data(),
            displayFilename: "other.epub", addedAt: Date(), fileType: .epub)
        sample(5)
        XCTAssertNil(manager.activeSentenceRange)
    }

    func testRepeatedWordsUseTheirOwnUTF16Range() throws {
        let confirmed = PlaybackAudioOutput.Position(chapterIndex: 3, seconds: 12, duration: 30,
            sentenceID: "sentence", itemSeconds: 2, itemDuration: 4)
        let projected = ReaderAudioHighlightPresentation.projected(confirmed, age: 0.25, rate: 2)
        XCTAssertEqual(projected.seconds, 12.5, accuracy: 0.001)
        XCTAssertEqual(projected.itemSeconds, 2.5, accuracy: 0.001)
        XCTAssertEqual(projected.chapterIndex, confirmed.chapterIndex)
        XCTAssertEqual(projected.sentenceID, confirmed.sentenceID)
        let bounded = ReaderAudioHighlightPresentation.projected(confirmed, age: 10, rate: 4)
        XCTAssertLessThan(bounded.itemSeconds, confirmed.itemDuration,
                          "Interpolation must not invent the next sentence before confirmed output")
        let text = "👋 eco eco"
        let alignment = try XCTUnwrap(SpeechAudioAlignment(tag: SpeechAudioAlignmentTests.tag(
            #"[{"version":1,"text":"👋 eco eco","audioStart":0,"sourceOffset":0,"words":[{"location":7,"length":3,"start":8,"end":9}]}]"#)))
        let measured = try XCTUnwrap(alignment.spokenWord(at: 8.5))
        XCTAssertEqual(ReaderSpokenTextResolver.word(measured.word, passage: measured.passage,
            chapterText: text, renderedText: text), NSRange(location: 7, length: 3))
    }

    func testRepeatedSentencesAfterEmojiResolveInReadingOrder() {
        let chapter = EbookFulltext.Chapter(index: 1, name: nil, text: "👋 Olá. Eco. Eco.",
            html: nil, css: nil, charCount: nil, segments: nil)
        let ranges = ReaderAudioHighlightPresentation.sentenceRanges(spans: chapter.splitSentences(), in: chapter.text as NSString)
        XCTAssertEqual(ranges["1:1"]?.location, 8)
        XCTAssertEqual(ranges["1:2"]?.location, 13)
    }

    func testSpeechHighlightsRequireOutputCallbacksAndRejectPausedOrObsoleteUtterances() async throws {
        let synth = SpeechFallbackPlayerTests.FakeSynthesizer()
        let speech = SpeechFallbackPlayer(synthesizer: synth,
            sessionConfigurator: SpeechFallbackPlayerTests.FakeSpeechAudioSession())
        let delegateSource = AVSpeechSynthesizer()
        speech.speak(text: "First word")
        let old = try XCTUnwrap(synth.spoken.first)
        XCTAssertNil(speech.spokenWord, "Intent to speak is not confirmed output")
        speech.speechSynthesizer(delegateSource, willSpeakRangeOfSpeechString: NSRange(location: 0, length: 5), utterance: old)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(speech.spokenWord?.range, NSRange(location: 0, length: 5))
        speech.pause()
        XCTAssertNil(speech.spokenWord)
        speech.speechSynthesizer(delegateSource, willSpeakRangeOfSpeechString: NSRange(location: 6, length: 4), utterance: old)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(speech.spokenWord)
        speech.stop()
        speech.speak(text: "Replacement word")
        let current = try XCTUnwrap(synth.spoken.last)
        speech.speechSynthesizer(delegateSource, didFinish: old)
        speech.speechSynthesizer(delegateSource, willSpeakRangeOfSpeechString: NSRange(location: 0, length: 5), utterance: old)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(speech.state, .speaking)
        XCTAssertNil(speech.spokenWord)
        speech.speechSynthesizer(delegateSource, willSpeakRangeOfSpeechString: NSRange(location: 0, length: 11), utterance: current)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(speech.spokenWord?.text, "Replacement word")
        speech.speechSynthesizer(delegateSource, didFinish: current)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(speech.spokenWord)
        XCTAssertEqual(speech.state, .idle)
    }

    func testListeningActivitySessionCannotCreateOrEndAnActivity() async {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            let before = Set(Activity<ConversionActivityAttributes>.activities.map(\.id))
            let session = ConversionLiveActivitySession(jobID: UUID().uuidString, isManualConversion: false)
            await session.start(title: "Automatic listening fixture", bookID: "isolated-fixture")
            await session.setPhase(.completed)
            XCTAssertEqual(Set(Activity<ConversionActivityAttributes>.activities.map(\.id)), before)
        }
        #endif
    }
}
#endif
