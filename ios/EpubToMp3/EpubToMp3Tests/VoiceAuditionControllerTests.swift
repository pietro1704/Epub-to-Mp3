import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

@MainActor
final class VoiceAuditionControllerTests: XCTestCase {
    func testSuccessfulAuditionAndExplicitStopPreserveCapturedSelection() async {
        let selection = TtsSelection.selected(.piper)
        var played: [URL] = []
        let output = URL(fileURLWithPath: "/fixture/preview.mp3")
        let controller = VoiceAuditionController(renderer: { received, language in
            XCTAssertEqual(received, selection)
            XCTAssertEqual(language, "pt-BR")
            return output
        }, playback: { played.append($0); return true })
        await controller.start(selection: selection, language: "pt-BR").value
        XCTAssertEqual(controller.state, .playing)
        XCTAssertEqual(played, [output])
        XCTAssertEqual(selection, .selected(.piper))
        controller.stop()
        XCTAssertEqual(controller.state, .idle)
    }

    func testFailureIsPersistentAndNeverStartsPlayback() async {
        var played = false
        let controller = VoiceAuditionController(renderer: { _, _ in throw CocoaError(.fileReadCorruptFile) },
            playback: { _ in played = true; return true })
        await controller.start(selection: .selected(.piper), language: "pt-BR").value
        guard case .failed = controller.state else { return XCTFail("Failure must remain visible") }
        XCTAssertFalse(played)
        controller.stop()
    }

    func testCancellationBeforeRenderingDoesNotCreateAnotherOperation() async {
        var rendered = false
        let controller = VoiceAuditionController(renderer: { _, _ in
            rendered = true
            return URL(fileURLWithPath: "/fixture/preview.mp3")
        }, playback: { _ in XCTFail("Cancelled audition cannot play"); return true })
        let task = controller.start(selection: .selected(.piper), language: "pt-BR")
        controller.stop()
        await task.value
        XCTAssertFalse(rendered)
        XCTAssertEqual(controller.state, .idle)
    }

    func testPlaybackFailureStaysVisibleAfterSuccessfulRendering() async {
        let controller = VoiceAuditionController(renderer: { _, _ in
            URL(fileURLWithPath: "/fixture/decoded-preview.mp3")
        }, playback: { _ in false })
        await controller.start(selection: .selected(.piper), language: "pt-BR").value
        guard case .failed = controller.state else { return XCTFail("Playback failure must remain visible") }
        controller.stop()
    }

    func testLateReplacedResultCannotStartPlayback() async {
        let entered = expectation(description: "first render entered")
        var firstResult: CheckedContinuation<URL, Error>?
        var calls = 0
        var played: [String] = []
        let controller = VoiceAuditionController(renderer: { _, _ in
            calls += 1
            if calls == 1 {
                return try await withCheckedThrowingContinuation { continuation in
                    firstResult = continuation
                    entered.fulfill()
                }
            }
            return URL(fileURLWithPath: "/fixture/current.mp3")
        }, playback: { played.append($0.lastPathComponent); return true })
        let first = controller.start(selection: .selected(.piper), language: "pt-BR")
        await fulfillment(of: [entered], timeout: 2)
        await controller.start(selection: .selected(.piper), language: "en-US").value
        firstResult?.resume(returning: URL(fileURLWithPath: "/fixture/retired.mp3"))
        await first.value
        XCTAssertEqual(played, ["current.mp3"])
        XCTAssertEqual(controller.state, .playing)
        controller.stop()
    }
}
