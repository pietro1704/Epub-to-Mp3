#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderPageNavigationTests: XCTestCase {
    func testTransitionSerializesInputUntilTheRequestedOffsetIsCommitted() throws {
        let suite = "reader-page-navigation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.pageTurnStyle = .none
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let scroll = UIScrollView(frame: host.bounds)
        scroll.contentSize = CGSize(width: 320, height: 1200)
        host.addSubview(scroll)
        let navigation = ReaderPageNavigation(view: host, scrollView: scroll,
            pageUnderflowGuard: UIView(), pageOverflowGuard: UIView(), settings: settings,
            beforeSnapshot: {})

        XCTAssertTrue(navigation.begin())
        XCTAssertFalse(navigation.begin(), "Repeated input cannot overlap an active page turn")
        navigation.setPageOffset(CGPoint(x: 0, y: 400), forward: true, outgoingPage: nil)
        XCTAssertEqual(scroll.contentOffset, CGPoint(x: 0, y: 400))
        XCTAssertEqual(scroll.transform, .identity, "Page turns must not animate vertical scrolling")
        XCTAssertTrue(navigation.begin(), "Committing the destination releases the next turn")
        navigation.settle()
    }

    func testUnavailableSnapshotStillCommitsTheDestinationAndReleasesInput() throws {
        let suite = "reader-page-snapshot-failure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.pageTurnStyle = .flip
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let scroll = UIScrollView(frame: host.bounds)
        scroll.contentSize = CGSize(width: 320, height: 1200)
        host.addSubview(scroll)
        let navigation = ReaderPageNavigation(view: host, scrollView: scroll,
            pageUnderflowGuard: UIView(), pageOverflowGuard: UIView(), settings: settings,
            beforeSnapshot: {})

        XCTAssertTrue(navigation.begin())
        navigation.setPageOffset(CGPoint(x: 0, y: 800), forward: false, outgoingPage: nil)
        XCTAssertEqual(scroll.contentOffset, CGPoint(x: 0, y: 800))
        XCTAssertTrue(navigation.begin(), "A missing snapshot must not leave the reader input locked")
        navigation.settle()
    }
}
#endif
