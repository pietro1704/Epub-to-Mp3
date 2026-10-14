#if os(iOS)
import XCTest

@testable import EpubToMp3

@MainActor
final class ReaderRootPresentationCoordinatorTests: XCTestCase {
    func testInitialChromeConfigurationDefersForcedRootLayout() {
        let root = ReaderRootLayoutTrackingView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let reader = UIView()
        let mini = UIView()
        root.addSubview(reader)
        root.addSubview(mini)
        let toMini = reader.bottomAnchor.constraint(equalTo: mini.topAnchor)
        let toRoot = reader.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        let coordinator = ReaderRootPresentationCoordinator()
        coordinator.configureChromeLayout(
            rootView: root,
            readerBottomToMiniPlayer: toMini,
            readerBottomToRoot: toRoot
        )
        coordinator.setReaderActive(true)

        var restoredViewport = false
        coordinator.applyChromeLayout(
            transition: nil,
            needsFinalLayout: true,
            deferInitialLayout: true,
            restoreViewport: { restoredViewport = true }
        )

        XCTAssertTrue(toMini.isActive)
        XCTAssertFalse(toRoot.isActive)
        XCTAssertEqual(root.layoutCount, 0,
                       "Initial constraints should use UIKit's natural first layout pass")
        XCTAssertFalse(restoredViewport,
                       "Initial setup has no captured viewport to restore")
    }

    func testLoadingAndInactiveReaderProduceExpectedPresentationFacts() {
        let coordinator = ReaderRootPresentationCoordinator()

        coordinator.setReaderActive(true)
        XCTAssertTrue(coordinator.setLoading(true))
        XCTAssertTrue(coordinator.state.showsReaderNavigation)
        XCTAssertFalse(coordinator.state.hidesBottomChrome)
        XCTAssertFalse(coordinator.state.showsMiniPlayer(bookHasPlayback: true))

        coordinator.setReaderActive(false)

        XCTAssertEqual(coordinator.state, ReaderPresentationState())
    }

    func testNewestChromeTransitionCommitsAndRestoresOnce() throws {
        let coordinator = ReaderRootPresentationCoordinator()
        var captures = 0
        var events: [String] = []

        coordinator.setReaderActive(true)
        let hidden = coordinator.beginChromeTransition(to: true) { captures += 1 }
        let shown = coordinator.beginChromeTransition(to: false) { captures += 1 }

        XCTAssertFalse(coordinator.commit(
            try XCTUnwrap(hidden),
            applyFinalGeometry: { events.append("stale-geometry") },
            restoreViewport: { events.append("stale-restore") },
            needsFinalLayout: true
        ))
        XCTAssertTrue(coordinator.commit(
            try XCTUnwrap(shown),
            applyFinalGeometry: { events.append("final-geometry") },
            restoreViewport: { events.append("restore") },
            needsFinalLayout: true
        ))
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(events, ["final-geometry", "restore"])
    }

    func testRepeatedChromeRequestDoesNotStartViewportTransition() {
        let coordinator = ReaderRootPresentationCoordinator()
        coordinator.setReaderActive(true)
        var captures = 0

        XCTAssertNil(coordinator.beginChromeTransition(to: false) { captures += 1 })
        XCTAssertEqual(captures, 0)

        let hidden = coordinator.beginChromeTransition(to: true) { captures += 1 }
        XCTAssertNotNil(hidden)
        XCTAssertNil(coordinator.beginChromeTransition(to: true) { captures += 1 })
        XCTAssertEqual(captures, 1)
    }

    func testLeavingReaderInvalidatesAnOutstandingChromeTransition() throws {
        let coordinator = ReaderRootPresentationCoordinator()
        var restored = false

        coordinator.setReaderActive(true)
        let transition = try XCTUnwrap(coordinator.beginChromeTransition(to: true, captureViewport: {}))
        coordinator.setReaderActive(false)

        XCTAssertFalse(coordinator.commit(
            transition,
            applyFinalGeometry: {},
            restoreViewport: { restored = true },
            needsFinalLayout: true
        ))
        XCTAssertFalse(restored)
    }

    func testRefreshCommitAppliesFinalGeometryBeforeRestoration() {
        let coordinator = ReaderRootPresentationCoordinator()
        var events: [String] = []

        XCTAssertTrue(coordinator.commit(
            nil,
            applyFinalGeometry: { events.append("geometry") },
            restoreViewport: { events.append("restore") },
            needsFinalLayout: true
        ))

        XCTAssertEqual(events, ["geometry", "restore"])
    }

    func testChromeLayoutAtomicallySelectsOneReaderBottomOwner() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let reader = UIView()
        let mini = UIView()
        root.addSubview(reader)
        root.addSubview(mini)
        let toMini = reader.bottomAnchor.constraint(equalTo: mini.topAnchor)
        let toRoot = reader.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        let coordinator = ReaderRootPresentationCoordinator()
        coordinator.configureChromeLayout(
            rootView: root,
            readerBottomToMiniPlayer: toMini,
            readerBottomToRoot: toRoot
        )

        coordinator.setReaderActive(true)
        coordinator.applyChromeLayout(transition: nil, needsFinalLayout: true, restoreViewport: {})
        XCTAssertTrue(toMini.isActive)
        XCTAssertFalse(toRoot.isActive)

        XCTAssertTrue(coordinator.setLoading(true))
        coordinator.applyChromeLayout(transition: nil, needsFinalLayout: true, restoreViewport: {})
        XCTAssertTrue(toMini.isActive)
        XCTAssertFalse(toRoot.isActive)
    }
}

@MainActor
private final class ReaderRootLayoutTrackingView: UIView {
    private(set) var layoutCount = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutCount += 1
    }
}
#endif
