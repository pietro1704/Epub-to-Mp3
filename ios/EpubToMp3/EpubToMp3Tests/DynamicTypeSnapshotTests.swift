//
//  DynamicTypeSnapshotTests.swift
//  EpubToMp3Tests
//
//  Regression snapshots for the three most-used screens at
//  DynamicTypeSize.accessibility3 (XXXL). Each test verifies that
//  the layout does not clip text or collapse interactive elements.
//
//  The `.accessibility3` size is one step below `.accessibility5`
//  (the absolute maximum) and represents the population of users
//  who have explicitly enabled the Larger Accessibility Sizes option.
//  It is the worst-case we guarantee support for.
//
//  Reference images are committed after the first record run.
//  Bootstrap:
//   1. Set `SnapshotConfig.record = true`
//   2. xcodebuild test -only-testing:EpubToMp3Tests/DynamicTypeSnapshotTests \
//        -scheme EpubToMp3 -destination "platform=iOS Simulator,name=iPhone 16"
//   3. Flip back to `false`, commit the PNGs.
//

#if DEBUG && canImport(SnapshotTesting) && canImport(UIKit)
import XCTest
import SwiftUI
import SnapshotTesting
@testable import EpubToMp3

private final class DynamicTypeNavigationController: UINavigationController {
    private let contentSizeCategory: UIContentSizeCategory

    init(rootViewController: UIViewController, contentSizeCategory: UIContentSizeCategory) {
        self.contentSizeCategory = contentSizeCategory
        super.init(rootViewController: rootViewController)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setOverrideTraitCollection(
            UITraitCollection(preferredContentSizeCategory: contentSizeCategory),
            forChild: topViewController
        )
    }
}

private struct LibraryDynamicTypeSnapshotHost: UIViewControllerRepresentable {
    let store: LibraryStore
    let settings: AppSettings
    let bookmarks: BookmarkStore
    let contentSizeCategory: UIContentSizeCategory

    func makeUIViewController(context: Context) -> UINavigationController {
        DynamicTypeNavigationController(
            rootViewController: LibraryScreenController(
                library: store,
                settings: settings,
                bookmarkStore: bookmarks
            ),
            contentSizeCategory: contentSizeCategory
        )
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        (controller.viewControllers.first as? LibraryScreenController)?.refreshFromStores()
    }
}

private struct SettingsDynamicTypeSnapshotHost: UIViewControllerRepresentable {
    let settings: AppSettings
    let library: LibraryStore
    let player: AudioPlayer
    let playbackClock: PlaybackClock
    let contentSizeCategory: UIContentSizeCategory

    func makeUIViewController(context: Context) -> UINavigationController {
        DynamicTypeNavigationController(
            rootViewController: SettingsScreenController(
                settings: settings,
                library: library,
                player: player,
                playbackClock: playbackClock
            ),
            contentSizeCategory: contentSizeCategory
        )
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        (controller.viewControllers.first as? SettingsScreenController)?.refreshFromStores()
    }
}

@MainActor
final class DynamicTypeSnapshotTests: XCTestCase {

    // MARK: - Helpers

    private func makeLibrarySettings() -> (LibraryStore, AppSettings) {
        let suite = "snapshot.dyntype.library.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (LibraryStore(), AppSettings(defaults: defaults))
    }

    private func makeReaderSettings(theme: ReaderTheme = .light) -> AppSettings {
        let suite = "snapshot.dyntype.reader.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let s = AppSettings(defaults: defaults)
        s.readerTheme = theme
        return s
    }

    private func makePlayerSettings() -> AppSettings {
        let suite = "snapshot.dyntype.player.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    // MARK: - Library — empty state at accessibility3

    func testLibraryEmptyStateXXXL() {
        let (store, settings) = makeLibrarySettings()
        let view = LibraryDynamicTypeSnapshotHost(
            store: store,
            settings: settings,
            bookmarks: BookmarkStore(),
            contentSizeCategory: .accessibilityExtraExtraExtraLarge
        )
        // iPhone SE is the worst-case (narrowest) device.
        assertDeviceSnapshot(
            of: view,
            on: SnapshotDevices.iPhoneSEPortrait,
            named: "Library-Empty-accessibility3"
        )
    }

    // MARK: - Library — populated grid at accessibility3

    func testLibraryPopulatedXXXL() {
        let (_, settings) = makeLibrarySettings()
        let view = LibraryDynamicTypeSnapshotHost(
            store: LibraryStore.previewPopulated,
            settings: settings,
            bookmarks: BookmarkStore(),
            contentSizeCategory: .accessibilityExtraExtraExtraLarge
        )
        assertSnapshots(
            of: view,
            on: [SnapshotDevices.iPhoneSEPortrait, SnapshotDevices.iPhone15ProPortrait],
            named: "Library-Populated-accessibility3"
        )
    }

    // MARK: - Reader at accessibility3

    func testReaderLightXXXL() {
        let sample = EbookFulltext.previewSample
        let chapter = sample.chapters.first!
        let view = ReaderView(
            chapter: chapter,
            spans: chapter.splitSentences(),
            currentSentenceId: nil
        )
        .environmentObject(makeReaderSettings(theme: .light))
        .environment(\.dynamicTypeSize, .accessibility3)
        assertSnapshots(
            of: view,
            on: [SnapshotDevices.iPhoneSEPortrait, SnapshotDevices.iPhone15ProPortrait],
            named: "Reader-Light-accessibility3"
        )
    }

    func testReaderDarkXXXL() {
        let sample = EbookFulltext.previewSample
        let chapter = sample.chapters.first!
        let view = ReaderView(
            chapter: chapter,
            spans: chapter.splitSentences(),
            currentSentenceId: nil
        )
        .environmentObject(makeReaderSettings(theme: .dark))
        .environment(\.dynamicTypeSize, .accessibility3)
        assertDeviceSnapshot(
            of: view,
            on: SnapshotDevices.iPhone15ProPortrait,
            named: "Reader-Dark-accessibility3"
        )
    }

    // MARK: - Settings at accessibility3

    func testSettingsXXXL() {
        let suite = "snapshot.dyntype.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        let player = AudioPlayer()
        let view = SettingsDynamicTypeSnapshotHost(
            settings: settings,
            library: LibraryStore(),
            player: player,
            playbackClock: player.playbackClock,
            contentSizeCategory: .accessibilityExtraExtraExtraLarge
        )
        assertSnapshots(
            of: view,
            on: [SnapshotDevices.iPhoneSEPortrait, SnapshotDevices.iPhone15ProPortrait],
            named: "Settings-accessibility3"
        )
    }
}
#endif
