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

    func testFailedInstallationPresentsItsErrorOnMainActorWithoutChangingSelection() async throws {
        let suite = "MacModelInstallationFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.secondaryAudioEngine = .edge
        settings.allowOnlineAudioFallback = true
        let original = settings.conversionOptions
        let installer = BlockingModelInstaller()
        defer { installer.release() }
        let message = "Owned fixture installation failed"
        let controller = MacSettingsViewController(
            settings: settings, library: LibraryStore(defaults: defaults),
            installPiperModelOperation: { modelID, root in
                _ = installer.install(modelID: modelID, root: root)
                throw NSError(domain: "MacModelInstallationFixture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        )
        _ = controller.view
        let button = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString("installPiperModel") })
        let presented = expectation(description: "Owned installation error alert was presented")
        let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard let modal = NSApp.modalWindow else { return }
                defer { timer.invalidate(); NSApp.abortModal(); modal.orderOut(nil) }
                let labels = modal.contentView.map { self.descendants($0) } ?? []
                let text = labels.compactMap { $0 as? NSTextField }.map(\.stringValue)
                XCTAssertTrue(text.contains(message), "The actual alert must retain the installer error")
                XCTAssertTrue(text.contains(L10n.string("settings.piperInstall")))
                XCTAssertTrue(Thread.isMainThread)
                presented.fulfill()
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        button.performClick(nil)
        await fulfillment(of: [presented, installer.completed], timeout: 5)
        let result = installer.result()
        XCTAssertFalse(result.mainThread)
        XCTAssertTrue(result.heartbeat)
        XCTAssertEqual(result.modelID, "pt_BR-faber-medium")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(settings.conversionOptions, original)
        XCTAssertNil(NSApp.modalWindow, "Dismiss the owned fixture alert before finishing")
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
#endif
