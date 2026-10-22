#if canImport(AVFoundation) && canImport(MediaPlayer)
import AVFoundation
import Foundation
import XCTest
#if os(iOS)
import UIKit
#endif

@testable import EpubToMp3

extension AudioPlayerPendingSeekTests {
    @MainActor
    func testFinalFileConfirmationClampsExistingPendingSeekAndPreservesPause() async throws {
        try await verifyLateEndConfirmation(finalFile: true)
    }

    @MainActor
    func testSegmentEndConfirmationResolvesExistingPendingSeekAndPreservesPause() async throws {
        try await verifyLateEndConfirmation(finalFile: false)
    }

    @MainActor
    func testPauseWinsWhenEndConfirmationArrivesBeforeDurationTaskRuns() async throws {
        try await verifyLateEndConfirmation(finalFile: false, confirmImmediately: true)
    }
}
#endif
