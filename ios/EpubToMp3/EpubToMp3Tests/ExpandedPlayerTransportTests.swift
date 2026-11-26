#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class ExpandedPlayerTransportTests: XCTestCase {
    /// The button renders the committed transport state, published after the current main-actor turn.
    private func waitForLabel(_ button: UIButton, _ label: String) async throws {
        for _ in 0..<100 where button.accessibilityLabel != label {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func makeController(
        player: AudioPlayer,
        startListening: @escaping () -> Void
    ) throws -> (FullPlayerScreenController, UIButton) {
        let suite = "expanded-transport-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let controller = FullPlayerScreenController(
            player: player,
            library: LibraryStore(defaults: defaults),
            playerPresentation: PlayerPresentation(defaults: defaults),
            settings: AppSettings(defaults: defaults), onStartListening: startListening
        )
        controller.loadViewIfNeeded()
        func descendants(_ view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let button = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "fullPlayer.playPause" })
        return (controller, button)
    }

    func testFirstPlayInvokesListeningInsteadOfOnlyArmingAutoplay() throws {
        let player = AudioPlayer()
        var starts = 0
        let (controller, button) = try makeController(player: player) { starts += 1 }
        withExtendedLifetime(controller) {
            button.sendActions(for: .touchUpInside)
            XCTAssertEqual(starts, 1)
            XCTAssertFalse(player.hasPendingAutoplay, "A resume with no producer is not a listening start")
            XCTAssertFalse(player.hasLoadedAudioQueue)
        }
    }

    func testRepeatedTapDuringPreparationDoesNotStartAnotherConversion() throws {
        let player = AudioPlayer()
        var starts = 0
        let (controller, button) = try makeController(player: player) {
            starts += 1
            player.isConverting = true
        }
        defer { player.isConverting = false }
        withExtendedLifetime(controller) {
            button.sendActions(for: .touchUpInside)
            button.sendActions(for: .touchUpInside)
            XCTAssertEqual(starts, 1)
            XCTAssertTrue(player.hasPendingAutoplay)
        }
    }

    func testPlayPauseControlsTheSameSpeechSessionWithoutStartingAnotherProducer() async throws {
        let synth = SpeechFallbackPlayerTests.FakeSynthesizer()
        let fallback = SpeechFallbackPlayer(
            synthesizer: synth, sessionConfigurator: SpeechFallbackPlayerTests.FakeSpeechAudioSession()
        )
        let player = AudioPlayer(speechFallback: fallback)
        player.playFallbackSpeech(text: "Isolated silent transport fixture")
        defer { fallback.stop() }
        let unrelatedPlayer = AudioPlayer()
        let (controller, button) = try makeController(player: player) {
            XCTFail("An existing speech session must receive transport commands")
        }
        defer { withExtendedLifetime(controller) {} }
        do {
            button.sendActions(for: .touchUpInside)
            XCTAssertFalse(player.isPlaying)
            XCTAssertEqual(synth.pauseCalls, 1)
            try await waitForLabel(button, L10n.string("player.play"))
            XCTAssertEqual(button.accessibilityLabel, L10n.string("player.play"))
            button.sendActions(for: .touchUpInside)
            XCTAssertTrue(player.isPlaying)
            XCTAssertEqual(synth.continueCalls, 1)
            try await waitForLabel(button, L10n.string("player.pause"))
            XCTAssertEqual(button.accessibilityLabel, L10n.string("player.pause"))
            XCTAssertFalse(unrelatedPlayer.isPlaying)
            XCTAssertFalse(unrelatedPlayer.hasPendingAutoplay)
        }
    }
}
#endif
