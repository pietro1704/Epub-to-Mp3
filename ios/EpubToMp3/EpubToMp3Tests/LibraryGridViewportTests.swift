#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class LibraryGridViewportTests: XCTestCase {
    func testLibraryScreenUsesTheSafeAreaBoundaryWithoutAShellPlayer() throws {
        let suite = "library-viewport-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let controller = LibraryScreenController(
            library: LibraryStore(defaults: defaults), settings: AppSettings(defaults: defaults),
            player: player, playerPresentation: PlayerPresentation(defaults: defaults),
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks")
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.additionalSafeAreaInsets.bottom = 49
        controller.view.layoutIfNeeded()
        let grid = try XCTUnwrap(controller.children.compactMap { $0 as? LibraryGridController }.first)
        let bottom = grid.collectionView.convert(grid.collectionView.bounds, to: controller.view).maxY
        XCTAssertEqual(bottom, controller.view.safeAreaLayoutGuide.layoutFrame.maxY, accuracy: 0.5)
        XCTAssertEqual(controller.additionalSafeAreaInsets.bottom, 49)
    }

    func testCollectionViewEndsAtPlayerTopAndRestoresSafeAreaWhenRemoved() {
        let fixture = Fixture()
        defer { fixture.close() }
        let safeBottom = fixture.host.view.safeAreaLayoutGuide.layoutFrame.maxY
        let player = CGRect(x: 0, y: safeBottom - 64, width: 390, height: 64)
        fixture.update(player)
        XCTAssertEqual(fixture.collectionBottom, player.minY, accuracy: 0.5)
        XCTAssertEqual(fixture.grid.collectionView.contentInset.bottom, 0)
        fixture.update(nil)
        XCTAssertEqual(fixture.collectionBottom, safeBottom, accuracy: 0.5)
    }

    func testRepeatedVisibilityAndReplacementPlayerUseLatestGeometryWithoutAccumulation() {
        let fixture = Fixture()
        defer { fixture.close() }
        for top in [CGFloat(650), 650, 710, 620, 710] {
            fixture.update(CGRect(x: 0, y: top, width: 390, height: 60))
            XCTAssertEqual(fixture.collectionBottom, top, accuracy: 0.5)
            fixture.update(nil)
            XCTAssertEqual(fixture.collectionBottom,
                           fixture.host.view.safeAreaLayoutGuide.layoutFrame.maxY, accuracy: 0.5)
        }
    }

    func testOffscreenAndEmptyPlayerDoNotReserveSpace() {
        let fixture = Fixture()
        defer { fixture.close() }
        for frame in [CGRect.zero, CGRect(x: 500, y: 650, width: 100, height: 60),
                      CGRect(x: 0, y: 900, width: 390, height: 60)] {
            fixture.update(frame)
            XCTAssertEqual(fixture.collectionBottom,
                           fixture.host.view.safeAreaLayoutGuide.layoutFrame.maxY, accuracy: 0.5)
        }
    }

    func testRotationAndAlreadyReservedAccessorySafeAreaStillUseActualPlayerTop() {
        let fixture = Fixture()
        defer { fixture.close() }
        for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390)] {
            fixture.window.frame.size = size
            fixture.host.view.frame = fixture.window.bounds
            fixture.host.additionalSafeAreaInsets.bottom = 100
            fixture.host.view.layoutIfNeeded()
            let top = fixture.host.view.bounds.maxY - 80
            fixture.update(CGRect(x: 0, y: top, width: size.width, height: 60))
            XCTAssertEqual(fixture.collectionBottom, top, accuracy: 0.5)
            XCTAssertEqual(fixture.host.additionalSafeAreaInsets.bottom, 100)
            fixture.update(nil)
            XCTAssertEqual(fixture.collectionBottom,
                           fixture.host.view.safeAreaLayoutGuide.layoutFrame.maxY, accuracy: 0.5)
        }
    }

    @MainActor
    private final class Fixture {
        let host = UIViewController()
        let grid = LibraryGridController(metrics: .init())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let viewport: LibraryGridViewport

        init() {
            host.addChild(grid)
            host.view.addSubview(grid.view)
            grid.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                grid.view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
                grid.view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
                grid.view.topAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.topAnchor),
            ])
            viewport = LibraryGridViewport(grid: grid.view, container: host.view)
            grid.didMove(toParent: host)
            window.rootViewController = host
            window.isHidden = false
            host.additionalSafeAreaInsets.bottom = 49
            host.view.layoutIfNeeded()
        }

        var collectionBottom: CGFloat {
            grid.collectionView.convert(grid.collectionView.bounds, to: host.view).maxY
        }

        func update(_ frame: CGRect?) {
            viewport.update(in: host.view, miniPlayerFrame: frame)
            host.view.layoutIfNeeded()
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }
}
#endif
