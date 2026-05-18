//
//  PlayerReaderToolbarSnapshotTests.swift
//  EpubToMp3Tests
//
//  Regression snapshot for the HIG-compliant toolbar in
//  `PlayerReaderView`. The toolbar must collapse to ≤3 visible buttons
//  (close + TOC + overflow menu) with the rest grouped under an
//  `ellipsis.circle` Menu — matching Apple Books / Music. A diff in
//  the captured PNG flags a regression of the consolidation.
//

#if DEBUG && canImport(SnapshotTesting) && canImport(UIKit)
import XCTest
import SwiftUI
import SnapshotTesting
@testable import EpubToMp3

@MainActor
final class PlayerReaderToolbarSnapshotTests: XCTestCase {

    private func makeStack() -> (
        player: AudioPlayer,
        library: LibraryStore,
        settings: AppSettings,
        bookmarks: BookmarkStore
    ) {
        let suite = "snapshot.playerReader.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        let player = AudioPlayer()
        let library = LibraryStore.previewPopulated
        let bookmarks = BookmarkStore.previewPopulated
        return (player, library, settings, bookmarks)
    }

    /// Captures the toolbar in its default idle state. The snapshot
    /// regression-checks that the toolbar uses the `ellipsis.circle`
    /// overflow grouping rather than 8 inline buttons.
    func testToolbarCompactIPhones() {
        let stack = makeStack()
        let view = PlayerReaderView(
            snapshot: JobSnapshot.previewSample,
            backendBaseURL: URL(string: "http://localhost:8000")
        )
        .environmentObject(stack.player)
        .environmentObject(stack.library)
        .environmentObject(stack.settings)
        .environmentObject(stack.bookmarks)

        assertSnapshots(
            of: view,
            on: SnapshotDevices.iPhonesPortrait,
            named: "PlayerReaderToolbar-Default"
        )
    }
}
#endif
