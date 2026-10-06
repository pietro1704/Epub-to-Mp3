import Foundation
import XCTest
@testable import EpubToMp3
#if os(macOS)
import AppKit
private typealias DiagnosticsSettingsController = MacSettingsViewController
#elseif os(iOS)
import UIKit
private typealias DiagnosticsSettingsController = SettingsScreenController
#endif

#if os(macOS) || os(iOS)
final class StreamingDiagnosticsSettingsTests: XCTestCase {
    #if os(iOS)
    @MainActor private var diagnosticsRows: [ObjectIdentifier: IndexPath] = [:]
    #endif
    @MainActor
    func testActualSettingsControlRequiresConsentAndStopsWithoutAnotherPrompt() throws {
        let session = StreamingDiagnosticsSession(clock: { 0 })
        var confirmation: (() -> Void)?
        var prompts = 0
        let fixture = try makeFixture(session: session) { title, message, accept in
            prompts += 1
            XCTAssertEqual(title, L10n.string("settings.streamingDiagnosticsConfirmTitle"))
            XCTAssertEqual(message, L10n.string("settings.streamingDiagnosticsConfirmMessage"))
            XCTAssertNotEqual(message, "settings.streamingDiagnosticsConfirmMessage")
            confirmation = accept
        }
        defer { fixture.cleanup() }
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(try controlTitle(fixture.controller), L10n.string("settings.recordStreamingDiagnostics"))
        try tapControl(fixture.controller)
        XCTAssertEqual(prompts, 1)
        XCTAssertFalse(session.isActive, "Presenting a confirmation is not consent.")
        try XCTUnwrap(confirmation)()
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(try controlTitle(fixture.controller), L10n.string("settings.stopStreamingDiagnostics"))
        try tapControl(fixture.controller)
        XCTAssertEqual(prompts, 1, "Stopping must never require confirmation.")
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(try controlTitle(fixture.controller), L10n.string("settings.recordStreamingDiagnostics"))
    }

    @MainActor
    func testVisibleControlRefreshesWhenConsentExpiresWithoutPolling() async throws {
        var now: UInt64 = 0
        let session = StreamingDiagnosticsSession(clock: { now })
        session.activate()
        now = 299_990_000_000
        let fixture = try makeFixture(session: session) { _, _, _ in XCTFail("Expiry must not request consent.") }
        defer { fixture.cleanup() }
        show(fixture.controller)
        XCTAssertEqual(try controlTitle(fixture.controller), L10n.string("settings.stopStreamingDiagnostics"))
        now = 300_000_000_000
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(try controlTitle(fixture.controller), L10n.string("settings.recordStreamingDiagnostics"))
    }

    @MainActor
    func testReopenedSettingsRefreshesExpiredConsentAndFreshSessionStartsOff() throws {
        var now: UInt64 = 0
        let session = StreamingDiagnosticsSession(clock: { now })
        session.activate()
        let fixture = try makeFixture(session: session) { _, _, _ in XCTFail("Visibility changes are not consent.") }
        defer { fixture.cleanup() }
        hide(fixture.controller)
        now = 300_000_000_000
        show(fixture.controller)
        XCTAssertEqual(try controlTitle(fixture.controller), L10n.string("settings.recordStreamingDiagnostics"))
        let restarted = StreamingDiagnosticsSession(clock: { now })
        let freshFixture = try makeFixture(session: restarted) { _, _, _ in XCTFail("Restart is not consent.") }
        defer { freshFixture.cleanup() }
        XCTAssertFalse(restarted.isActive)
        XCTAssertEqual(try controlTitle(freshFixture.controller), L10n.string("settings.recordStreamingDiagnostics"))
    }

    @MainActor
    private func makeFixture(
        session: StreamingDiagnosticsSession,
        confirm: @escaping (String, String, @escaping () -> Void) -> Void
    ) throws -> (controller: DiagnosticsSettingsController, cleanup: () -> Void) {
        let identifier = "DiagnosticsSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        let settings = AppSettings(defaults: defaults)
        let library = LibraryStore(defaults: defaults)
        #if os(macOS)
        let controller = MacSettingsViewController(settings: settings, library: library,
            diagnosticsSession: session, confirmStreamingDiagnostics: confirm)
        _ = controller.view
        return (controller, {
            self.hide(controller)
            defaults.removePersistentDomain(forName: identifier)
        })
        #else
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let controller = SettingsScreenController(settings: settings, library: library, player: player,
            playbackClock: PlaybackClock(), diagnosticsSession: session, confirmStreamingDiagnostics: confirm)
        let previousKeyWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        return (controller, {
            self.hide(controller)
            self.diagnosticsRows.removeValue(forKey: ObjectIdentifier(controller))
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
            defaults.removePersistentDomain(forName: identifier)
        })
        #endif
    }

    @MainActor
    private func show(_ controller: DiagnosticsSettingsController) {
        #if os(macOS)
        controller.viewWillAppear()
        #else
        controller.viewWillAppear(false)
        #endif
    }

    @MainActor
    private func hide(_ controller: DiagnosticsSettingsController) {
        #if os(macOS)
        controller.viewDidDisappear()
        #else
        controller.viewDidDisappear(false)
        #endif
    }

    #if os(macOS)
    @MainActor
    private func button(in root: NSView) throws -> NSButton {
        if let button = root as? NSButton,
           button.accessibilityIdentifier() == "settings.recordStreamingDiagnostics" { return button }
        for child in root.subviews {
            if let found = try? button(in: child) { return found }
        }
        throw NSError(domain: "StreamingDiagnosticsSettingsTests", code: 1)
    }

    @MainActor
    private func controlTitle(_ controller: DiagnosticsSettingsController) throws -> String {
        try button(in: controller.view).title
    }

    @MainActor
    private func tapControl(_ controller: DiagnosticsSettingsController) throws {
        try button(in: controller.view).performClick(nil)
    }
    #else
    @MainActor
    private func controlRow(_ controller: DiagnosticsSettingsController) throws -> IndexPath {
        if let row = diagnosticsRows[ObjectIdentifier(controller)] { return row }
        for section in 0..<controller.numberOfSections(in: controller.tableView) {
            for row in 0..<controller.tableView(controller.tableView, numberOfRowsInSection: section) {
                let index = IndexPath(row: row, section: section)
                let cell = controller.tableView(controller.tableView, cellForRowAt: index)
                if cell.accessibilityIdentifier == "settings.recordStreamingDiagnostics" {
                    diagnosticsRows[ObjectIdentifier(controller)] = index
                    return index
                }
            }
        }
        throw NSError(domain: "StreamingDiagnosticsSettingsTests", code: 1)
    }

    @MainActor
    private func controlTitle(_ controller: DiagnosticsSettingsController) throws -> String {
        let row = try controlRow(controller)
        if controller.tableView.cellForRow(at: row) == nil {
            controller.tableView.scrollToRow(at: row, at: .middle, animated: false)
            controller.tableView.layoutIfNeeded()
        }
        let cell = try XCTUnwrap(controller.tableView.cellForRow(at: row))
        return try XCTUnwrap((cell.contentConfiguration as? UIListContentConfiguration)?.text)
    }

    @MainActor
    private func tapControl(_ controller: DiagnosticsSettingsController) throws {
        controller.tableView(controller.tableView, didSelectRowAt: try controlRow(controller))
    }
    #endif
}
#endif
