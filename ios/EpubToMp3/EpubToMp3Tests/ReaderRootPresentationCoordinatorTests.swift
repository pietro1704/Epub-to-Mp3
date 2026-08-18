#if os(iOS)
import XCTest

@testable import EpubToMp3

@MainActor
final class ReaderRootPresentationCoordinatorTests: XCTestCase {
    func testLoadingAndInactiveReaderProduceExpectedPresentationFacts() {
        let coordinator = ReaderRootPresentationCoordinator()

        coordinator.setReaderActive(true)
        XCTAssertTrue(coordinator.setLoading(true))
        XCTAssertTrue(coordinator.state.showsReaderNavigation)
        XCTAssertTrue(coordinator.state.hidesBottomChrome)
        XCTAssertFalse(coordinator.state.showsMiniPlayer(bookHasPlayback: true))

        coordinator.setReaderActive(false)

        XCTAssertEqual(coordinator.state, ReaderPresentationState())
    }

    func testNewestChromeTransitionCommitsAndRestoresOnce() {
        let coordinator = ReaderRootPresentationCoordinator()
        var captures = 0
        var events: [String] = []

        let hidden = coordinator.beginChromeTransition(to: true) { captures += 1 }
        let shown = coordinator.beginChromeTransition(to: false) { captures += 1 }

        XCTAssertFalse(coordinator.commit(
            hidden,
            applyFinalGeometry: { events.append("stale-geometry") },
            restoreViewport: { events.append("stale-restore") },
            needsFinalLayout: true
        ))
        XCTAssertTrue(coordinator.commit(
            shown,
            applyFinalGeometry: { events.append("final-geometry") },
            restoreViewport: { events.append("restore") },
            needsFinalLayout: true
        ))
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(events, ["final-geometry", "restore"])
    }

    func testLeavingReaderInvalidatesAnOutstandingChromeTransition() {
        let coordinator = ReaderRootPresentationCoordinator()
        var restored = false

        coordinator.setReaderActive(true)
        let transition = coordinator.beginChromeTransition(to: true, captureViewport: {})
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
        XCTAssertFalse(toMini.isActive)
        XCTAssertTrue(toRoot.isActive)
    }
}
#endif
