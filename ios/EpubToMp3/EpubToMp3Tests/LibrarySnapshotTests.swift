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

@MainActor
final class LibrarySnapshotTests: XCTestCase {

    private func makeEmptyLibrary() -> (LibraryStore, AppSettings) {
        let suite = "snapshot.library.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = LibraryStore()
        let settings = AppSettings(defaults: defaults)
        return (store, settings)
    }

    // MARK: - Empty state hero

    func testLibraryEmptyStateIPhones() {
        let (store, settings) = makeEmptyLibrary()
        let view = LibraryView()
            .environmentObject(store)
            .environmentObject(settings)
        assertSnapshots(of: view, on: SnapshotDevices.iPhonesPortrait,
                        named: "Library-Empty")
    }

    func testLibraryEmptyStateIPad() {
        let (store, settings) = makeEmptyLibrary()
        let view = LibraryView()
            .environmentObject(store)
            .environmentObject(settings)
        assertDeviceSnapshot(of: view,
                             on: SnapshotDevices.iPadPro12_9Portrait,
                             named: "Library-Empty-iPadPro")
    }
}
#endif
