//
//  ReaderSnapshotTests.swift
//  EpubToMp3Tests
//
//  Regression snapshots for `ReaderView` across the full device matrix
//  and every theme. The bug that motivated this suite (2026-05-12):
//  a 12pt reader margin in portrait rendered the first/last glyphs
//  outside the safe content area on iPhone SE. The clamp now lives in
//  `AppSettings.readerMargin` (min 16pt) AND in `ReaderView`'s
//  `effectiveReaderMargin` helper. These snapshots lock the rendered
//  geometry so any future regression is caught at PR time.
//
//  Bootstrap (first run, references not yet in repo):
//   1. Flip `SnapshotConfig.record` to `true`.
//   2. `xcodebuild test -only-testing:EpubToMp3Tests/ReaderSnapshotTests \
//        -scheme EpubToMp3 -destination "platform=iOS Simulator,name=iPhone 16"`
//   3. Flip back to `false`, commit the generated PNGs.
//

#if DEBUG && canImport(SnapshotTesting) && canImport(UIKit)
import XCTest
import SwiftUI
import SnapshotTesting
@testable import EpubToMp3

@MainActor
final class ReaderSnapshotTests: XCTestCase {

    /// Fresh AppSettings backed by an isolated UserDefaults suite so
    /// the snapshot run is reproducible regardless of host state.
    private func makeSettings(
        theme: ReaderTheme = .light,
        margin: Double = 24
    ) -> AppSettings {
        let suite = "snapshot.reader.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        settings.readerTheme = theme
        settings.readerMargin = margin
        return settings
    }

    private func makeReaderView(
        chapter: EbookFulltext.Chapter? = nil
    ) -> some View {
        let sample = EbookFulltext.previewSample
        let ch = chapter ?? sample.chapters.first!
        let spans = ch.splitSentences()
        return ReaderView(
            chapter: ch,
            spans: spans,
            currentSentenceId: nil
        )
    }

    // MARK: - Default theme × full device matrix

    func testReaderLightThemeAcrossFullMatrix() {
        let view = makeReaderView()
            .environmentObject(makeSettings(theme: .light))
        assertSnapshots(of: view, on: SnapshotDevices.fullMatrix,
                        named: "Reader-Light")
    }

    // MARK: - Dark theme × portrait iPhones

    func testReaderDarkThemePortraitIPhones() {
        let view = makeReaderView()
            .environmentObject(makeSettings(theme: .dark))
        assertSnapshots(of: view, on: SnapshotDevices.iPhonesPortrait,
                        named: "Reader-Dark")
    }

    // MARK: - Sepia theme × iPads

    func testReaderSepiaThemeIPads() {
        let view = makeReaderView()
            .environmentObject(makeSettings(theme: .sepia))
        assertSnapshots(of: view, on: SnapshotDevices.iPadsPortrait,
                        named: "Reader-Sepia")
    }

    // MARK: - Regression: 16pt margin clamp

    /// Locks the fix for the 2026-05-12 portrait-clipping bug. Even when
    /// a stale UserDefaults persists a pre-clamp value, the rendered
    /// margin must not drop below 16pt. We deliberately *try* to set
    /// 12pt; the model layer should bump it to 16pt and the snapshot
    /// pixel diff against the 16pt reference proves the clamp held.
    func testReaderMarginClampedTo16ptPortrait() {
        let settings = makeSettings(theme: .light, margin: 12)
        XCTAssertGreaterThanOrEqual(settings.readerMargin, 16,
            "Stale 12pt margin must be coerced to ≥16pt by AppSettings")
        let view = makeReaderView()
            .environmentObject(settings)
        // Single device — iPhone SE is the worst-case width (320pt
        // logical, smallest text-area budget).
        assertDeviceSnapshot(of: view,
                             on: SnapshotDevices.iPhoneSEPortrait,
                             named: "Reader-MarginClamp-16pt")
    }
}
#endif
