//
//  PlayerSnapshotTests.swift
//  EpubToMp3Tests
//
//  Regression snapshots for the playback surfaces: `MiniPlayerBar`
//  and the iOS `FullPlayerScreenController`. We render each with an
//  isolated player stack so the captured PNGs track the real platform
//  surface instead of an extra SwiftUI host layer.
//

#if DEBUG && canImport(SnapshotTesting) && canImport(UIKit)
import XCTest
import SwiftUI
import SnapshotTesting
@testable import EpubToMp3

#if os(iOS)
private struct FullPlayerControllerSnapshotHost: UIViewControllerRepresentable {
    let player: AudioPlayer
    let library: LibraryStore
    let presentation: PlayerPresentation

    func makeUIViewController(context: Context) -> FullPlayerScreenController {
        FullPlayerScreenController(
            player: player,
            playbackClock: player.playbackClock,
            library: library,
            playerPresentation: presentation
        )
    }

    func updateUIViewController(_ controller: FullPlayerScreenController, context: Context) {
        controller.refresh(library: library)
    }
}
#endif

@MainActor
final class PlayerSnapshotTests: XCTestCase {

    /// Isolated player + library + settings stack. Snapshot tests must
    /// be reproducible — no shared singletons. `@MainActor` because
    /// `AudioPlayer` is main-actor-isolated.
    private func makeStack() -> (player: AudioPlayer, library: LibraryStore, settings: AppSettings, presentation: PlayerPresentation) {
        let suite = "snapshot.player.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        let player = AudioPlayer()
        let library = LibraryStore()
        let presentation = PlayerPresentation()
        return (player, library, settings, presentation)
    }

    // MARK: - MiniPlayerBar

    /// MiniPlayerBar renders nothing when no current book is loaded;
    /// the snapshot suite still captures the empty case so a regression
    /// that makes it render an empty shell is caught.
    func testMiniPlayerEmptyStateIPhones() {
        let stack = makeStack()
        let view = MiniPlayerBar(onTap: {})
            .environmentObject(stack.player)
            .environmentObject(stack.player.playbackClock)
            .environmentObject(stack.library)
        assertSnapshots(of: view, on: SnapshotDevices.iPhonesPortrait,
                        named: "MiniPlayer-Empty")
    }

    // MARK: - Full player (no current item — covers the empty-state branch)

    func testFullPlayerControllerEmptyIPhones() {
        let stack = makeStack()
        let view = FullPlayerControllerSnapshotHost(
            player: stack.player,
            library: stack.library,
            presentation: stack.presentation
        )
        assertSnapshots(of: view, on: SnapshotDevices.iPhonesPortrait,
                        named: "FullPlayer-Empty")
    }

    func testFullPlayerControllerEmptyIPad() {
        let stack = makeStack()
        let view = FullPlayerControllerSnapshotHost(
            player: stack.player,
            library: stack.library,
            presentation: stack.presentation
        )
        assertDeviceSnapshot(of: view,
                             on: SnapshotDevices.iPadPro12_9Portrait,
                             named: "FullPlayer-Empty-iPad")
    }
}
#endif
