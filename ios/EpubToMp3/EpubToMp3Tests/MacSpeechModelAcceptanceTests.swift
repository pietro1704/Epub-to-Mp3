#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MacSpeechModelAcceptanceTests: XCTestCase {
    func testOptInVisibleInstallProgressReadinessAndExplicitSelection() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EPUB2MP3_MODEL_INSTALL_ACCEPTANCE"] == "1",
              let supplied = environment["TTS_TEST_INSTALLED_MODELS_ROOT"] else {
            throw XCTSkip("Requires explicitly supplied, already verified catalogue artifacts")
        }
        let id = "pt_BR-cadu-medium"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-ui-\(UUID().uuidString)")
        let suite = "MacSpeechModelAcceptance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            MacSpeechModelArtifactProtocol.reset()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let adapter = ConverterFFIAdapter()
        let current = SpeechModelLibraryTarget.current()
        let target = SpeechModelLibraryTarget(
            language: "pt-BR", platform: "macos", androidAPI: 0,
            architecture: current.architecture, osVersion: current.osVersion, modelsRoot: root
        )
        let source = URL(fileURLWithPath: supplied).appendingPathComponent(id)
        let sourceTarget = SpeechModelLibraryTarget(
            language: target.language, platform: target.platform, androidAPI: 0,
            architecture: target.architecture, osVersion: target.osVersion,
            modelsRoot: URL(fileURLWithPath: supplied)
        )
        let verified = try adapter.speechModelSnapshot(target: sourceTarget)
        XCTAssertEqual(verified.entries.first { $0.identity.modelID == id }?.installation.state, .installed)
        let plan = try preparePlan(adapter: adapter, root: root, modelID: id)
        MacSpeechModelArtifactProtocol.configure(plan, source: source)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MacSpeechModelArtifactProtocol.self]
        let client = SpeechModelLibraryClient(
            target: target, adapter: adapter,
            transfer: SpeechModelBackgroundTransfer(configuration: configuration)
        )
        let settings = AppSettings(defaults: defaults)
        settings.selectPrimaryNarration(.selected(.system))
        settings.selectSecondaryNarration(nil)
        let original = settings.ttsPreferences
        let controller = MacSettingsViewController(
            settings: settings, library: LibraryStore(defaults: defaults), speechModels: client
        )
        let previous = NSApp.keyWindow
        let window = NSWindow(contentViewController: controller)
        window.title = "Speech model acceptance"
        window.setContentSize(NSSize(width: 1100, height: 850))
        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
        defer { window.close(); previous?.makeKeyAndOrderFront(nil) }

        try await waitUntil { window.isVisible && NSApp.isActive && window.isKeyWindow }
        try MacSpeechModelTestControls.revealModels(in: controller.view)
        try await waitUntil { self.button("\(id).install", in: controller.view) != nil }
        XCTAssertTrue(window.isVisible && NSApp.isActive)
        let install = try XCTUnwrap(button("\(id).install", in: controller.view))
        install.scrollToVisible(install.bounds)
        attach(controller.view, name: "01-model-list")
        install.performClick(nil)
        try await waitUntil { window.attachedSheet != nil }
        XCTAssertEqual(MacSpeechModelArtifactProtocol.requestCount, 0,
                       "Opening confirmation cannot start a download")
        let sheet = try XCTUnwrap(window.attachedSheet)
        let confirm = try XCTUnwrap(descendants(try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSButton }
            .first { $0.title == L10n.string("settings.modelInstall.confirm") })
        attach(try XCTUnwrap(sheet.contentView), name: "02-explicit-confirmation")
        confirm.performClick(nil)
        let intermediateProgress = (1..<100).map { L10n.string("settings.modelInstall.downloading", $0) }
        try await waitUntil {
            guard self.button("\(id).cancel", in: controller.view) != nil,
                  let details = self.descendants(controller.view).compactMap({ $0 as? NSTextField })
                    .first(where: { $0.accessibilityIdentifier() == "settings.speechModel.\(id).details" }) else { return false }
            return intermediateProgress.contains { details.stringValue.contains($0) }
        }
        attach(controller.view, name: "03-install-progress")
        try await waitUntil { self.button("\(id).select", in: controller.view) != nil }

        XCTAssertEqual(settings.ttsPreferences, original, "A verified installation never selects itself")
        let installed = try await client.snapshot()
        let entry = try XCTUnwrap(installed.entries.first { $0.identity.modelID == id })
        XCTAssertEqual(entry.installation.state, .installed)
        XCTAssertEqual(entry.readiness.state, .ready, "The actual bundled Piper must load the model")
        XCTAssertEqual(entry.identity.modelRevision, plan.revision)
        let requestsBeforeSelection = MacSpeechModelArtifactProtocol.requestCount
        let select = try XCTUnwrap(button("\(id).select", in: controller.view))
        select.scrollToVisible(select.bounds)
        select.performClick(nil)
        XCTAssertEqual(settings.ttsPreferences.primary.modelID, id)
        XCTAssertEqual(settings.ttsPreferences.primary.session?.modelRevision, plan.revision)
        XCTAssertEqual(MacSpeechModelArtifactProtocol.requestCount, requestsBeforeSelection,
                       "Explicit selection cannot trigger another download")
        attach(controller.view, name: "04-ready-and-selected")
    }

    private func preparePlan(adapter: ConverterFFIAdapter, root: URL, modelID: String) throws -> SpeechModelInstallPlan {
        let operation = try adapter.makeModelInstallOperation(modelID: modelID, root: root, availableBytes: .max)
        defer { operation.cancel() }
        return try operation.plan()
    }

    private func button(_ suffix: String, in view: NSView) -> NSButton? {
        descendants(view).compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "settings.speechModel.\(suffix)"
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func attach(_ view: NSView, name: String) {
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return XCTFail("Cannot capture the actual visible Settings surface")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Cannot encode Settings evidence")
        }
        let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
