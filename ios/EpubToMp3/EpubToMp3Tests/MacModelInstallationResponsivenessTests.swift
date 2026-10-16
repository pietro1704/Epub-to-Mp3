#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

private final class BlockingModelInstaller: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var heartbeatBeforeRelease = false
    private var ranOnMainThread = false
    private var requestedModel: String?
    private var requests = 0
    let completed = XCTestExpectation(description: "Fake model installer returned")

    func install(modelID: String, root: String) -> URL {
        condition.lock()
        ranOnMainThread = Thread.isMainThread
        requestedModel = modelID
        requests += 1
        condition.unlock()
        Task { @MainActor in self.heartbeatAndRelease() }
        // A blocked MainActor cannot deliver the heartbeat. This owned watchdog
        // releases the fake anyway, so a regression fails instead of hanging.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { self.release() }
        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
        completed.fulfill()
        return URL(fileURLWithPath: root).appendingPathComponent(modelID)
    }

    private func heartbeatAndRelease() {
        condition.lock()
        heartbeatBeforeRelease = !released
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func result() -> (heartbeat: Bool, mainThread: Bool, modelID: String?, count: Int) {
        condition.lock()
        defer { condition.unlock() }
        return (heartbeatBeforeRelease, ranOnMainThread, requestedModel, requests)
    }
}

@MainActor
final class MacModelInstallationResponsivenessTests: XCTestCase {
    func testInstallingFaberKeepsMainActorResponsiveWithoutChangingSelection() async throws {
        let suite = "MacModelInstallation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.audioEngine = .edge
        let original = settings.conversionOptions
        let installer = BlockingModelInstaller()
        defer { installer.release() }
        let controller = MacSettingsViewController(
            settings: settings, library: LibraryStore(defaults: defaults),
            installPiperModelOperation: { installer.install(modelID: $0, root: $1) }
        )
        _ = controller.view
        let button = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString("installPiperModel") })
        button.performClick(nil)
        await fulfillment(of: [installer.completed], timeout: 5)
        let result = installer.result()
        XCTAssertFalse(result.mainThread, "Synchronous model installation must not run on the main thread")
        XCTAssertTrue(result.heartbeat, "The MainActor must run while installation is still blocked")
        XCTAssertEqual(result.modelID, "pt_BR-faber-medium")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(settings.conversionOptions, original, "Installing a voice must not change saved selections")
        XCTAssertNotNil(button.target)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
#endif
