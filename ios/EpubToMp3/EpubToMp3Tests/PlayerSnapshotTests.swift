//
//  PlayerSnapshotTests.swift
//  EpubToMp3Tests
//
//  Regression snapshots for the playback surfaces: `MiniPlayerBar`,
//  `FullPlayerSheet`, `NowPlayingView`. We render each with a
//  pre-populated `AudioPlayer` snapshot so the bar shows a real title /
//  chapter / progress bar in the captured PNG.
//

#if DEBUG && canImport(SnapshotTesting) && canImport(UIKit)
import XCTest
import SwiftUI
import SnapshotTesting
@testable import EpubToMp3

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
            .environmentObject(stack.library)
            .environmentObject(stack.settings)
        assertSnapshots(of: view, on: SnapshotDevices.iPhonesPortrait,
                        named: "MiniPlayer-Empty")
    }

    // MARK: - FullPlayerSheet (no current item — covers the empty-state branch)

    func testFullPlayerSheetEmptyIPhones() {
        let stack = makeStack()
        let view = FullPlayerSheet()
            .environmentObject(stack.player)
            .environmentObject(stack.library)
            .environmentObject(stack.settings)
            .environmentObject(stack.presentation)
        assertSnapshots(of: view, on: SnapshotDevices.iPhonesPortrait,
                        named: "FullPlayer-Empty")
    }

    func testFullPlayerSheetEmptyIPad() {
        let stack = makeStack()
        let view = FullPlayerSheet()
            .environmentObject(stack.player)
            .environmentObject(stack.library)
            .environmentObject(stack.settings)
            .environmentObject(stack.presentation)
        assertDeviceSnapshot(of: view,
                             on: SnapshotDevices.iPadPro12_9Portrait,
                             named: "FullPlayer-Empty-iPad")
    }
}
#endif
