import XCTest
@testable import EpubToMp3

#if os(iOS)
import UIKit

@MainActor
final class PlayerPlaybackClockTests: XCTestCase {
    func testMiniPlayerClockTickUpdatesProgressWithoutDecodingArtworkAgain() async throws {
        let suiteName = "PlayerPlaybackClockTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        let standard = UserDefaults.standard
        let bookID = "clock-test-\(UUID().uuidString)"
        let keys = [
            ReaderSessionState.currentlyReadingBookIDKey,
            AudioPlayer.currentBookIDDefaultsKey,
        ]
        let previousValues = keys.map { standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previousValues) {
                if let value {
                    standard.set(value, forKey: key)
                } else {
                    standard.removeObject(forKey: key)
                }
            }
        }

        let cover = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let coverData = try XCTUnwrap(cover.pngData())
        let decodedCoverSize = try XCTUnwrap(UIImage(data: coverData)).size
        let book = BookEntity(
            id: bookID,
            title: "Clock Test",
            bookmark: Data([1]),
            displayFilename: "clock-test.epub",
            addedAt: Date(),
            coverPNG: coverData
        )
        suite.set(try JSONEncoder().encode([book]), forKey: "books")
        standard.set(bookID, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        standard.set(bookID, forKey: AudioPlayer.currentBookIDDefaultsKey)

        let player = AudioPlayer()
        let library = LibraryStore(defaults: suite, defaultsKey: "books")
        XCTAssertEqual(library.books.map(\.id), [bookID])
        XCTAssertEqual(MiniPlayerBarUIKitView.activeBookID(), bookID)
        let miniPlayer = MiniPlayerBarUIKitView()
        miniPlayer.configure(
            player: player,
            playbackClock: player.playbackClock,
            library: library,
            onTap: {}
        )

        let coverView = try XCTUnwrap(descendants(of: miniPlayer, matching: UIImageView.self)
            .first(where: { $0.image?.size == decodedCoverSize }),
            "Expected decoded book artwork. Found image sizes: \(descendants(of: miniPlayer, matching: UIImageView.self).compactMap(\.image?.size))")
        let originalCover = try XCTUnwrap(coverView.image)
        let originalCoverData = try XCTUnwrap(originalCover.pngData())
        let slider = try XCTUnwrap(descendants(of: miniPlayer, matching: CompactSlider.self).first)

        player.playbackClock.update(positionSeconds: 12, durationSeconds: 180)
        await waitForMainQueue()

        XCTAssertEqual(slider.value, 12, accuracy: 0.01)
        XCTAssertEqual(coverView.image?.pngData(), originalCoverData)
    }

    func testPlayerScreenClockTickUpdatesProgressWithoutRebuildingRateMenu() async throws {
        let snapshot = try makeSnapshot()
        let player = AudioPlayer()
        player.setSnapshot(snapshot)
        let controller = PlayerScreenController(
            snapshot: snapshot,
            backendBaseURL: nil,
            player: player,
            playbackClock: player.playbackClock
        )
        controller.loadViewIfNeeded()

        let rateButton = try XCTUnwrap(buttonsWithMenus(in: controller.view).first)
        let originalMenu = try XCTUnwrap(rateButton.menu)
        let slider = try XCTUnwrap(descendants(of: controller.view, matching: CompactSlider.self).first)

        player.playbackClock.update(positionSeconds: 18, durationSeconds: 240)
        await waitForMainQueue()

        XCTAssertEqual(slider.value, 18, accuracy: 0.01)
        XCTAssertTrue(rateButton.menu === originalMenu)
    }

    func testFullPlayerClockTickUpdatesProgressWithoutRebuildingMenus() async throws {
        let suiteName = "full-player-clock.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let player = AudioPlayer()
        let controller = FullPlayerScreenController(
            player: player,
            playbackClock: player.playbackClock,
            library: LibraryStore(),
            playerPresentation: PlayerPresentation(defaults: defaults),
            settings: AppSettings(defaults: defaults)
        )
        controller.loadViewIfNeeded()

        let originalMenus = buttonsWithMenus(in: controller.view).compactMap(\.menu)
        XCTAssertGreaterThanOrEqual(originalMenus.count, 2)
        let sliders = descendants(of: controller.view, matching: CompactSlider.self)
        let slider = try XCTUnwrap(sliders.first)

        player.playbackClock.update(positionSeconds: 24, durationSeconds: 300)
        await waitForMainQueue()

        XCTAssertEqual(slider.value, 24, accuracy: 0.01)
        XCTAssertEqual(buttonsWithMenus(in: controller.view).compactMap(\.menu).count, originalMenus.count)
        for (button, originalMenu) in zip(buttonsWithMenus(in: controller.view), originalMenus) {
            XCTAssertTrue(button.menu === originalMenu)
        }
    }

    private func makeSnapshot() throws -> JobSnapshot {
        let data = Data(#"{"jobId":"playback-clock-test","state":"completed","bookTitle":"Clock Test"}"#.utf8)
        return try JSONDecoder().decode(JobSnapshot.self, from: data)
    }

    private func waitForMainQueue() async {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    private func buttonsWithMenus(in root: UIView) -> [UIButton] {
        descendants(of: root, matching: UIButton.self).filter { $0.menu != nil }
    }

    private func descendants<View: UIView>(of root: UIView, matching type: View.Type) -> [View] {
        var result: [View] = []
        if let match = root as? View {
            result.append(match)
        }
        for child in root.subviews {
            result.append(contentsOf: descendants(of: child, matching: type))
        }
        return result
    }
}
#endif
