//
//  LibrarySnapshotTests.swift
//  EpubToMp3Tests
//
//  Regression snapshots for `LibraryView` — both the empty-state hero
//  and the populated grid. `LibrarySidebar` is iPad-only and rendered
//  at the iPad Pro 12.9 trait so the split-view sidebar layout is
//  captured too.
//

#if DEBUG && canImport(SnapshotTesting) && canImport(UIKit)
import XCTest
import SwiftUI
import SnapshotTesting
@testable import EpubToMp3

private struct LibraryScreenSnapshotHost: UIViewControllerRepresentable {
    let store: LibraryStore
    let settings: AppSettings
    let bookmarks: BookmarkStore

    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(
            rootViewController: LibraryScreenController(
                library: store,
                settings: settings,
                bookmarkStore: bookmarks
            )
        )
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        (controller.viewControllers.first as? LibraryScreenController)?.refreshFromStores()
    }
}

@MainActor
final class LibrarySnapshotTests: XCTestCase {

    private func makeEmptyLibrary() -> (LibraryStore, AppSettings, BookmarkStore) {
        let suite = "snapshot.library.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = LibraryStore()
        let settings = AppSettings(defaults: defaults)
        return (store, settings, BookmarkStore())
    }

    // MARK: - Empty state hero

    func testLibraryEmptyStateIPhones() {
        let (store, settings, bookmarks) = makeEmptyLibrary()
        let view = LibraryScreenSnapshotHost(
            store: store,
            settings: settings,
            bookmarks: bookmarks
        )
        assertSnapshots(of: view, on: SnapshotDevices.iPhonesPortrait,
                        named: "Library-Empty")
    }

    func testLibraryEmptyStateIPad() {
        let (store, settings, bookmarks) = makeEmptyLibrary()
        let view = LibraryScreenSnapshotHost(
            store: store,
            settings: settings,
            bookmarks: bookmarks
        )
        assertDeviceSnapshot(of: view,
                             on: SnapshotDevices.iPadPro12_9Portrait,
                             named: "Library-Empty-iPadPro")
    }
}
#endif
