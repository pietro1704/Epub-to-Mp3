import XCTest
@testable import EpubToMp3

#if os(iOS)
import UIKit

@MainActor
final class MiniPlayerBarLayoutTests: XCTestCase {
    func testOverlayMiniPlayerUsesItsIntrinsicContentHeight() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let miniPlayer = MiniPlayerBarUIKitView()
        miniPlayer.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(miniPlayer)

        NSLayoutConstraint.activate([
            miniPlayer.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            miniPlayer.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            miniPlayer.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutIfNeeded()

        XCTAssertEqual(miniPlayer.bounds.height, miniPlayer.intrinsicContentSize.height, accuracy: 0.5)
    }

    func testContentStackCentersWithinPill() throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let miniPlayer = MiniPlayerBarUIKitView()
        miniPlayer.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(miniPlayer)

        NSLayoutConstraint.activate([
            miniPlayer.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            miniPlayer.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            miniPlayer.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            miniPlayer.heightAnchor.constraint(equalToConstant: MiniPlayerLayoutMetrics.maximumOverlayHeight),
        ])
        host.layoutIfNeeded()

        let materialView = try XCTUnwrap(pillMaterial(in: miniPlayer))
        let contentStack = try XCTUnwrap(
            miniPlayer.subviews.first(where: { $0 is UIStackView })
        )
        let materialCenter = materialView.convert(
            CGPoint(x: materialView.bounds.midX, y: materialView.bounds.midY),
            to: miniPlayer
        )
        let contentCenter = contentStack.convert(
            CGPoint(x: contentStack.bounds.midX, y: contentStack.bounds.midY),
            to: miniPlayer
        )

        XCTAssertEqual(contentCenter.y, materialCenter.y, accuracy: 0.5)
    }

    func testOverlayKeepsThePillAboveTheBottomSafeAreaWhileFillingTheScreenEdge() throws {
        let hostController = UIViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = hostController
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        hostController.additionalSafeAreaInsets.bottom = 34
        hostController.loadViewIfNeeded()

        let miniPlayer = MiniPlayerBarUIKitView()
        miniPlayer.translatesAutoresizingMaskIntoConstraints = false
        hostController.view.addSubview(miniPlayer)
        NSLayoutConstraint.activate([
            miniPlayer.leadingAnchor.constraint(equalTo: hostController.view.leadingAnchor),
            miniPlayer.trailingAnchor.constraint(equalTo: hostController.view.trailingAnchor),
            miniPlayer.bottomAnchor.constraint(equalTo: hostController.view.bottomAnchor),
            miniPlayer.heightAnchor.constraint(equalToConstant: MiniPlayerLayoutMetrics.maximumOverlayHeight),
        ])
        hostController.view.layoutIfNeeded()

        XCTAssertGreaterThan(miniPlayer.safeAreaInsets.bottom, 0)
        let materialView = try XCTUnwrap(pillMaterial(in: miniPlayer))
        let bottomFill = try XCTUnwrap(bottomSafeAreaFill(in: miniPlayer))
        XCTAssertEqual(
            materialView.frame.maxY,
            miniPlayer.safeAreaLayoutGuide.layoutFrame.maxY,
            accuracy: 0.5
        )
        XCTAssertEqual(
            bottomFill.frame.minY,
            miniPlayer.safeAreaLayoutGuide.layoutFrame.maxY,
            accuracy: 0.5
        )
        XCTAssertEqual(bottomFill.frame.maxY, miniPlayer.bounds.maxY, accuracy: 0.5)

        let contentStack = try XCTUnwrap(
            miniPlayer.subviews.first(where: { $0 is UIStackView })
        )
        XCTAssertEqual(
            contentStack.frame.midY,
            materialView.frame.midY,
            accuracy: 0.5
        )
    }

    func testOpenButtonActivatesFullPlayerAndAnnouncesDisplayedMetadata() throws {
        let suite = "mini-player.layout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let player = AudioPlayer()
        let library = LibraryStore(defaults: defaults, defaultsKey: "books")
        let miniPlayer = MiniPlayerBarUIKitView()
        var openCount = 0
        miniPlayer.configure(
            player: player,
            playbackClock: player.playbackClock,
            library: library,
            onTap: { openCount += 1 }
        )

        let openButton = try XCTUnwrap(button(in: miniPlayer, identifier: "miniPlayer.open"))
        XCTAssertFalse(openButton.accessibilityValue?.isEmpty ?? true)
        openButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(openCount, 1)
    }

    func testReaderChapterTitleIsUsedBeforeAudioPlaybackStarts() throws {
        let player = AudioPlayer()
        player.updateReaderChapterTitle("Chapter One", for: 0)
        let miniPlayer = MiniPlayerBarUIKitView()
        miniPlayer.configure(
            player: player,
            playbackClock: player.playbackClock,
            library: LibraryStore(),
            onTap: {}
        )

        let openButton = try XCTUnwrap(button(in: miniPlayer, identifier: "miniPlayer.open"))
        XCTAssertTrue(openButton.accessibilityValue?.contains("Chapter One") ?? false)
    }

    func testReaderCurrentChapterTitleOverridesDefaultAudioCursorBeforePlayback() {
        let defaults = UserDefaults.standard
        let previousReaderIndex = defaults.object(forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        defer {
            restore(
                defaults,
                key: AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                value: previousReaderIndex
            )
        }

        let player = AudioPlayer()
        player.updateReaderChapterTitle("Epigraph", for: 0)
        player.updateReaderChapterTitle("Contents", for: 1)
        defaults.set(1, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)

        XCTAssertEqual(player.effectiveChapterTitle, "Contents")
    }

    func testPlayButtonRequestsLocalConversionWhenNoAudioQueueExists() throws {
        let player = AudioPlayer()
        let library = LibraryStore()
        let miniPlayer = MiniPlayerBarUIKitView()
        var requests = 0
        miniPlayer.configure(
            player: player,
            playbackClock: player.playbackClock,
            library: library,
            onTap: {},
            onPlayRequested: { requests += 1 }
        )

        let playButton = try XCTUnwrap(button(in: miniPlayer, identifier: "miniPlayer.playPause"))
        playButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(requests, 1)
        XCTAssertFalse(player.isPlaying)
    }

    func testSystemAccessoryExcludesAnAdditionalBottomSafeAreaInset() {
        let miniPlayer = MiniPlayerBarUIKitView(usesSystemManagedBottomInset: true)

        XCTAssertEqual(miniPlayer.intrinsicContentSize.height, 52, accuracy: 0.5)
    }

    func testActiveBookIDPrefersTheCurrentlyOpenReaderBook() throws {
        let suite = "mini-player.context.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("reader-book", forKey: ReaderSessionState.currentlyReadingBookIDKey)

        XCTAssertEqual(MiniPlayerBarUIKitView.activeBookID(defaults: defaults), "reader-book")

        defaults.set("playing-book", forKey: AudioPlayer.currentBookIDDefaultsKey)

        XCTAssertEqual(MiniPlayerBarUIKitView.activeBookID(defaults: defaults), "reader-book")
    }

    func testOpeningAnotherBookReplacesAnActivePlaybackSession() {
        XCTAssertTrue(
            MainReaderScreenController.shouldReplaceActivePlayback(
                activeBookID: "previous-book",
                incomingBookID: "next-book",
                hasActivePlayback: true
            )
        )
        XCTAssertFalse(
            MainReaderScreenController.shouldReplaceActivePlayback(
                activeBookID: "same-book",
                incomingBookID: "same-book",
                hasActivePlayback: true
            )
        )
        XCTAssertFalse(
            MainReaderScreenController.shouldReplaceActivePlayback(
                activeBookID: "previous-book",
                incomingBookID: "next-book",
                hasActivePlayback: false
            )
        )
    }

    func testReaderContextRendersBookMetadataWithoutPlayback() throws {
        let librarySuite = "mini-player.metadata.\(UUID().uuidString)"
        let libraryDefaults = try XCTUnwrap(UserDefaults(suiteName: librarySuite))
        defer { libraryDefaults.removePersistentDomain(forName: librarySuite) }
        let book = BookEntity(
            id: "reader-book",
            title: "Reader Book",
            bookmark: Data([1]),
            displayFilename: "reader-book.epub",
            addedAt: .now
        )
        libraryDefaults.set(try JSONEncoder().encode([book]), forKey: "books")
        let library = LibraryStore(defaults: libraryDefaults, defaultsKey: "books")
        XCTAssertEqual(library.books.map(\.id), [book.id])

        let defaults = UserDefaults.standard
        let playbackID = defaults.object(forKey: AudioPlayer.currentBookIDDefaultsKey)
        let readerID = defaults.object(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        defer {
            restore(defaults, key: AudioPlayer.currentBookIDDefaultsKey, value: playbackID)
            restore(defaults, key: ReaderSessionState.currentlyReadingBookIDKey, value: readerID)
        }
        defaults.removeObject(forKey: AudioPlayer.currentBookIDDefaultsKey)
        defaults.removeObject(forKey: ReaderSessionState.currentlyReadingBookIDKey)

        let player = AudioPlayer()
        let miniPlayer = MiniPlayerBarUIKitView()
        miniPlayer.configure(player: player, playbackClock: player.playbackClock, library: library, onTap: {})
        let openButton = try XCTUnwrap(button(in: miniPlayer, identifier: "miniPlayer.open"))
        XCTAssertFalse(openButton.accessibilityValue?.contains(book.title) ?? false)

        defaults.set(book.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        XCTAssertEqual(MiniPlayerBarUIKitView.activeBookID(), book.id)
        miniPlayer.refresh()

        XCTAssertTrue(
            openButton.accessibilityValue?.contains(book.title) ?? false,
            "Expected reader context to render \(book.title), got \(openButton.accessibilityValue ?? "nil")"
        )
    }

    func testOverlayMaximumHeightPreservesCompactControlsAndLargeSafeArea() {
        XCTAssertEqual(MiniPlayerLayoutMetrics.contentHeight, 52, accuracy: 0.5)
        XCTAssertEqual(MiniPlayerLayoutMetrics.maximumBottomSafeAreaInset, 44, accuracy: 0.5)
        XCTAssertEqual(
            MiniPlayerLayoutMetrics.maximumOverlayHeight,
            MiniPlayerLayoutMetrics.contentHeight + MiniPlayerLayoutMetrics.maximumBottomSafeAreaInset,
            accuracy: 0.5
        )
        XCTAssertEqual(MiniPlayerLayoutMetrics.maximumOverlayHeight, 96, accuracy: 0.5)
    }

    private func button(in view: UIView, identifier: String) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier {
            return button
        }
        for subview in view.subviews {
            if let button = button(in: subview, identifier: identifier) {
                return button
            }
        }
        return nil
    }

    private func pillMaterial(in view: UIView) -> AdaptiveMaterialView? {
        view.subviews.first {
            $0.accessibilityIdentifier == "miniPlayer.pillMaterial"
        } as? AdaptiveMaterialView
    }

    private func bottomSafeAreaFill(in view: UIView) -> AdaptiveMaterialView? {
        view.subviews.first {
            $0.accessibilityIdentifier == "miniPlayer.bottomSafeAreaFill"
        } as? AdaptiveMaterialView
    }

    private func restore(_ defaults: UserDefaults, key: String, value: Any?) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
#endif
