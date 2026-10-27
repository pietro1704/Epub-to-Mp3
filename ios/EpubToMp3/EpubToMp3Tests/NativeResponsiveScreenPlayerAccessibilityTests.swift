#if os(iOS) || os(macOS)
import XCTest
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@testable import EpubToMp3

extension NativeResponsiveScreenTests {
#if os(iOS)
    func testExpandedPlayerControlsRemainReachableWithLargeTextAndShortViewport() throws {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 568, height: 320)] {
            var displayedBook = book
            displayedBook.title = "Book"
            displayedBook.bookmark = Data([1])
            displayedBook.author = "An author whose complete name must stay visible in the expanded player"
            defaults.set(try JSONEncoder().encode([displayedBook]), forKey: "library.books.v1")
            let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
            defer { player.stop() }
            UserDefaults.standard.set(displayedBook.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
            UserDefaults.standard.set(displayedBook.id, forKey: AudioPlayer.currentBookIDDefaultsKey)
            let controller = FullPlayerScreenController(player: player, playbackClock: PlaybackClock(),
                library: LibraryStore(defaults: defaults), playerPresentation: PlayerPresentation(defaults: defaults),
                settings: AppSettings(defaults: defaults), onStartListening: {})
            let host = UIViewController()
            host.addChild(controller)
            host.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge),
                                            forChild: controller)
            host.view.addSubview(controller.view)
            controller.didMove(toParent: host)
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            // Exercise a live Dynamic Type transition after UIKit attaches its labels.
            host.setOverrideTraitCollection(nil, forChild: controller)
            host.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge),
                                            forChild: controller)
            host.view.frame = window.bounds
            controller.view.frame = host.view.bounds
            host.view.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            let scroll = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIScrollView }.first)
            XCTAssertGreaterThan(scroll.bounds.height, 100)
            let author = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UILabel }
                .first { $0.accessibilityIdentifier == "fullPlayer.bookAuthor" })
            XCTAssertEqual(author.text, displayedBook.author)
            XCTAssertFalse(author.isHidden)
            XCTAssertGreaterThan(author.font.pointSize, 30, "Font must scale in \(size): \(author.traitCollection.preferredContentSizeCategory)")
            XCTAssertGreaterThanOrEqual(author.bounds.height,
                author.sizeThatFits(CGSize(width: author.bounds.width, height: .greatestFiniteMagnitude)).height - 1)
            for identifier in ["fullPlayer.bookTitle", "fullPlayer.progress", "fullPlayer.playbackRateButton"] {
                let control = try XCTUnwrap(descendants(scroll).first { $0.accessibilityIdentifier == identifier },
                                            "Metadata and controls must share the scroll surface")
                scroll.scrollRectToVisible(control.convert(control.bounds, to: scroll), animated: false)
                XCTAssertTrue(scroll.bounds.insetBy(dx: -1, dy: -1).contains(control.convert(control.bounds, to: scroll)),
                              "Player control must be reachable: \(identifier), \(size)")
            }
        }
    }
#endif

#if os(iOS)
    func testExpandedPlayerMetadataFollowsAccessibilityTextSize() throws {
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let controller = FullPlayerScreenController(player: player, playbackClock: PlaybackClock(),
            library: LibraryStore(defaults: defaults), playerPresentation: PlayerPresentation(defaults: defaults),
            settings: AppSettings(defaults: defaults), onStartListening: {})
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
        controller.view.layoutIfNeeded()
        for identifier in ["fullPlayer.bookTitle", "fullPlayer.bookAuthor"] {
            let label = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UILabel }
                .first { $0.accessibilityIdentifier == identifier })
            XCTAssertTrue(label.adjustsFontForContentSizeCategory)
            XCTAssertEqual(label.numberOfLines, 0)
        }
    }
#endif

#if os(iOS)
    func testJobPlayerScrollsOnSEAndNamesIconControlsForVoiceOver() throws {
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let snapshot = try JSONDecoder().decode(JobSnapshot.self, from: Data("""
        {"jobId":"responsive-player","state":"completed","bookTitle":"A long audiobook title for a compact phone","chapterProgress":[]}
        """.utf8))
        player.play(snapshot: snapshot, startingAt: 0, restoreAutoplay: false)
        let controller = PlayerScreenController(snapshot: snapshot, backendBaseURL: nil,
                                                 player: player, playbackClock: PlaybackClock())
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
        controller.view.layoutIfNeeded()
        let views = descendants(controller.view)
        let scroll = try XCTUnwrap(views.compactMap { $0 as? UIScrollView }.first)
        let names = Set([L10n.string("player.previousChapter"), L10n.string("player.nextChapter"), L10n.string("player.play")])
        let controls = views.compactMap { $0 as? UIButton }.filter { names.contains($0.accessibilityLabel ?? "") }
        XCTAssertEqual(controls.count, 3)
        for control in controls {
            XCTAssertFalse((control.accessibilityLabel ?? "").isEmpty, "Icon transport must have a spoken name")
            XCTAssertGreaterThanOrEqual(control.bounds.height, 44)
            scroll.scrollRectToVisible(control.convert(control.bounds, to: scroll), animated: false)
            XCTAssertTrue(scroll.bounds.insetBy(dx: -1, dy: -1).contains(control.convert(control.bounds, to: scroll)))
        }
        let title = try XCTUnwrap(views.compactMap { $0 as? UILabel }.first { $0.text == snapshot.bookTitle })
        XCTAssertTrue(title.adjustsFontForContentSizeCategory)
        XCTAssertEqual(title.numberOfLines, 0)
    }
#endif

#if os(iOS)
#else
    func testExpandedPlayerFitsShortWindowAndNamesTransportControls() throws {
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let controller = MacFullPlayerViewController(player: player, library: LibraryStore(defaults: defaults),
            presentation: PlayerPresentation(defaults: defaults), onStartPlayback: {})
        try verifyMacScrolling(controller, sizes: [NSSize(width: 520, height: 300), NSSize(width: 900, height: 700)],
                               lastTitle: L10n.string("common.close"))
        let views = descendants(controller.view)
        for (identifier, key) in [("fullPlayer.previousChapter", "player.previousChapter"),
                                  ("fullPlayer.nextChapter", "player.nextChapter"),
                                  ("fullPlayer.playPause", "player.play")] {
            let control = try XCTUnwrap(views.compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == identifier })
            XCTAssertEqual(control.accessibilityLabel(), L10n.string(key))
            XCTAssertEqual(control.toolTip, L10n.string(key))
        }
        let slider = try XCTUnwrap(views.compactMap { $0 as? NSSlider }.first)
        XCTAssertEqual(slider.accessibilityLabel(), L10n.string("player.playbackPosition"))
    }
#endif
}
#endif
