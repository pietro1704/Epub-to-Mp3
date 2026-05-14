#if DEBUG && canImport(SnapshotTesting) && canImport(UIKit)
import XCTest
import SwiftUI
import SnapshotTesting
@testable import EpubToMp3

@MainActor
final class InstantReaderSnapshotTests: XCTestCase {

    private func makeSettings() -> AppSettings {
        let suite = "snapshot.instant.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    private struct Harness: View {
        let fulltext: EbookFulltext
        let banner: String?
        let hasAudio: Bool
        let settings: AppSettings
        @State private var snap: JobSnapshot? = nil

        var body: some View {
            InstantReaderView(
                fulltext: fulltext,
                snapshot: $snap,
                statusBanner: banner,
                hasAudio: hasAudio,
                backendBaseURL: nil,
                coverPNG: nil,
                onRequestAudioRetry: {}
            )
            .environmentObject(settings)
        }
    }

    func testInstantReaderIdleBarPortrait() {
        let view = Harness(
            fulltext: .previewSample,
            banner: nil,
            hasAudio: false,
            settings: makeSettings()
        )
        assertSnapshot(
            of: view,
            as: .image(precision: 0.95,
                       layout: .device(config: .iPhone8)),
            named: "InstantReader-Idle-iPhone8",
            record: true
        )
    }

    func testInstantReaderConvertingBarPortrait() {
        let view = Harness(
            fulltext: .previewSample,
            banner: "Generating audio · 3/12 ready",
            hasAudio: false,
            settings: makeSettings()
        )
        assertSnapshot(
            of: view,
            as: .image(precision: 0.95,
                       layout: .device(config: .iPhone8)),
            named: "InstantReader-Converting-iPhone8",
            record: true
        )
    }

    func testInstantReaderErrorBarPortrait() {
        let view = Harness(
            fulltext: .previewSample,
            banner: "Audio generation failed: transport error",
            hasAudio: false,
            settings: makeSettings()
        )
        assertSnapshot(
            of: view,
            as: .image(precision: 0.95,
                       layout: .device(config: .iPhone8)),
            named: "InstantReader-Error-iPhone8",
            record: true
        )
    }
}
#endif
