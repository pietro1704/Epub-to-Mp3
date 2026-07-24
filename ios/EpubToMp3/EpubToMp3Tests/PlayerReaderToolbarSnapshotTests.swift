//
//  PlayerReaderToolbarSnapshotTests.swift
//  EpubToMp3Tests
//
//  Regression snapshot for the UIKit player surface used on iPhone.
//  `PlayerReaderView` is desktop-first now; iOS routes the same job
//  detail playback flow through `PlayerScreenController`.
//

#if DEBUG && canImport(SnapshotTesting) && canImport(UIKit)
import XCTest
import SwiftUI
import SnapshotTesting
@testable import EpubToMp3

private struct PlayerScreenControllerSnapshotHost: UIViewControllerRepresentable {
    let snapshot: JobSnapshot
    let player: AudioPlayer

    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(
            rootViewController: PlayerScreenController(
                snapshot: snapshot,
                backendBaseURL: URL(string: "http://localhost:8000"),
                player: player,
                playbackClock: player.playbackClock
            )
        )
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        guard let root = controller.viewControllers.first as? PlayerScreenController else { return }
        root.update(snapshot: snapshot, backendBaseURL: URL(string: "http://localhost:8000"))
    }
}

@MainActor
final class PlayerReaderToolbarSnapshotTests: XCTestCase {

    private func makePlayer() -> AudioPlayer {
        AudioPlayer()
    }

    /// Captures the UIKit player in its default compact iPhone shell.
    func testPlayerScreenCompactIPhones() {
        let player = makePlayer()
        let view = PlayerScreenControllerSnapshotHost(
            snapshot: JobSnapshot.previewSample,
            player: player
        )

        assertSnapshots(
            of: view,
            on: SnapshotDevices.iPhonesPortrait,
            named: "PlayerScreen-Default"
        )
    }
}
#endif
