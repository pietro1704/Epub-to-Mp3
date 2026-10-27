#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

private final class ModelProductCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var installs: [String] = []
    private var removals: [String] = []
    let removed = XCTestExpectation(description: "One explicit removal reached the model module")

    func install(_ id: String, root: String) -> URL {
        lock.lock()
        installs.append(id)
        lock.unlock()
        return URL(fileURLWithPath: root).appendingPathComponent(id)
    }

    func remove(_ id: String) {
        lock.lock()
        removals.append(id)
        lock.unlock()
        removed.fulfill()
    }

    var counts: (installs: Int, removals: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (installs.count, removals)
    }
}

@MainActor
final class MacSpeechModelProductActionsTests: XCTestCase {
    func testSelectingAnotherReadyVoiceDoesNotInstallOrRemoveAnyModel() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let controller = MacSettingsViewController(
            settings: fixture.settings, library: LibraryStore(defaults: fixture.defaults),
            speechModels: fixture.client
        )
        controller.loadViewIfNeeded()
        let select = try button("pt_BR-cadu-medium.select", in: controller.view)

        select.performClick(nil)

        XCTAssertEqual(fixture.settings.ttsPreferences.primary.modelID, "pt_BR-cadu-medium")
        XCTAssertEqual(fixture.settings.ttsPreferences.primary.session?.modelRevision,
                       fixture.snapshot.entries.first { $0.identity.modelID == "pt_BR-cadu-medium" }?.identity.modelRevision)
        XCTAssertEqual(fixture.calls.counts.installs, 0)
        XCTAssertTrue(fixture.calls.counts.removals.isEmpty)
        XCTAssertFalse(descendants(controller.view).compactMap { $0 as? NSButton }.contains {
            $0.accessibilityIdentifier() == "settings.speechModel.pt_BR-cadu-medium.remove"
        })
    }

    func testRemovalNeedsConfirmationAndTargetsOnlyTheChosenModel() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let controller = MacSettingsViewController(
            settings: fixture.settings, library: LibraryStore(defaults: fixture.defaults),
            speechModels: fixture.client
        )
        controller.loadViewIfNeeded()
        let remove = try button("pt_BR-cadu-medium.remove", in: controller.view)
        let selection = fixture.settings.ttsPreferences
        try driveModal(buttonTitle: L10n.string("common.cancel")) { remove.performClick(nil) }
        XCTAssertTrue(fixture.calls.counts.removals.isEmpty)
        try driveModal(buttonTitle: L10n.string("common.remove")) { remove.performClick(nil) }
        await fulfillment(of: [fixture.calls.removed], timeout: 3)

        XCTAssertEqual(fixture.calls.counts.removals, ["pt_BR-cadu-medium"])
        XCTAssertEqual(fixture.calls.counts.installs, 0)
        XCTAssertEqual(fixture.settings.ttsPreferences, selection)
    }

    private func driveModal(buttonTitle: String, action: () -> Void) throws {
        var clicked = false
        let timer = Timer(timeInterval: 0.01, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard let content = NSApp.modalWindow?.contentView,
                      let choice = self.descendants(content).compactMap({ $0 as? NSButton })
                        .first(where: { $0.title == buttonTitle }) else { return }
                clicked = true
                timer.invalidate()
                choice.performClick(nil)
            }
        }
        let watchdog = Timer(timeInterval: 2, repeats: false) { _ in
            MainActor.assumeIsolated {
                if !clicked, let modal = NSApp.modalWindow {
                    NSApp.abortModal()
                    modal.orderOut(nil)
                }
            }
        }
        RunLoop.main.add(watchdog, forMode: .modalPanel)
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate(); watchdog.invalidate() }
        action()
        XCTAssertTrue(clicked, "The actual confirmation must be presented before removal")
    }

    private func button(_ suffix: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "settings.speechModel.\(suffix)"
        })
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private struct Fixture {
        let defaults: UserDefaults
        let suite: String
        let settings: AppSettings
        let client: SpeechModelLibraryClient
        let snapshot: SpeechModelSnapshot
        let calls: ModelProductCalls
        func cleanup() { defaults.removePersistentDomain(forName: suite) }
    }

    private func makeFixture() throws -> Fixture {
        let suite = "MacModelProductActions.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        settings.selectPrimaryNarration(.selected(.system))
        settings.selectSecondaryNarration(nil)
        let target = SpeechModelLibraryTarget(
            language: "pt-BR", platform: "macos", androidAPI: 0,
            architecture: "x86_64", osVersion: "test",
            modelsRoot: FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        )
        let inspected = try ConverterFFIAdapter().speechModelSnapshot(target: target)
        let entries = inspected.entries.map { entry -> SpeechModelSnapshot.Entry in
            guard ["pt_BR-faber-medium", "pt_BR-cadu-medium"].contains(entry.identity.modelID) else { return entry }
            return .init(
                identity: entry.identity, presentation: entry.presentation,
                languageEvidence: entry.languageEvidence, distribution: entry.distribution,
                licence: entry.licence, compatibility: entry.compatibility,
                installation: .init(state: .installed, verifiedRevision: entry.identity.modelRevision,
                                    installedBytes: entry.distribution.downloadBytes),
                readiness: .init(state: .ready, activeRuntimeRevision: "native-ui-fixture", failure: nil),
                selection: .init(selectable: true, reasons: [])
            )
        }
        let snapshot = SpeechModelSnapshot(
            schemaVersion: inspected.schemaVersion,
            generatedFromCatalogRevision: inspected.generatedFromCatalogRevision,
            defaultSelection: inspected.defaultSelection, target: inspected.target, entries: entries
        )
        let calls = ModelProductCalls()
        let client = SpeechModelLibraryClient(
            initialSnapshot: snapshot,
            install: { calls.install($0, root: $1) }, remove: { id, _ in calls.remove(id) }, target: target
        )
        return Fixture(defaults: defaults, suite: suite, settings: settings, client: client,
                       snapshot: snapshot, calls: calls)
    }
}
#endif
