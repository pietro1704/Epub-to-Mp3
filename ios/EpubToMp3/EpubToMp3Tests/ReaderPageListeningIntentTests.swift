import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderPageListeningIntentTests: XCTestCase {
    func testCompletedPartialAudioDelegatesReaderPageToANewTextRange() throws {
        let suite = "reader-page-intent-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let snapshot = try JSONDecoder().decode(JobSnapshot.self, from: Data(#"{"jobId":"partial","state":"finished","chapterProgress":[{"index":3,"status":"completed","textOffset":120}]}"#.utf8))
        player.setSnapshot(snapshot)
        var intents: [(Int, Double)] = []
        player.restartReaderListening = { chapter, ratio in
            intents.append((chapter, ratio))
            return true
        }
        player.startFromReaderPage(3, sentenceOffsetRatio: 0.7)
        XCTAssertEqual(intents.count, 1)
        XCTAssertEqual(intents.first?.0, 3)
        XCTAssertEqual(intents.first?.1, 0.7)
        XCTAssertNil(player.pendingNavigation, "The old partial timeline must never receive a proportional seek.")
        XCTAssertEqual(player.positionSeconds, 0)
        player.restartReaderListening = nil
    }
}
