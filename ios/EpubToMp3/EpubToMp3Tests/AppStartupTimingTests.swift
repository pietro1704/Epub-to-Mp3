import Foundation
import XCTest
@testable import EpubToMp3
#if os(macOS)
import AppKit
#endif

final class AppStartupTimingTests: XCTestCase {
    func testDisabledTimingDoesNotReadClockOrEmitAndPreservesOperation() throws {
        for arguments in [[], ["app"], ["-measureStartup=false"], ["--measureStartup"]] {
            let trace = StartupTraceCapture()
            let timing = trace.recorder(arguments: arguments)
            XCTAssertFalse(timing.isEnabled)
            XCTAssertEqual(timing.measure(.libraryDecodeApply) { 42 }, 42)
            XCTAssertTrue(trace.samples.isEmpty)
            XCTAssertEqual(trace.clockReads, 0)
        }
    }

    func testExactFlagEmitsMonotonicMillisecondsAndStructuredInclusiveRecord() throws {
        let trace = StartupTraceCapture()
        let timing = trace.recorder()
        XCTAssertTrue(timing.isEnabled)
        XCTAssertEqual(timing.measure(.libraryDecodeApply) { "private operation result" }, "private operation result")
        let sample = try XCTUnwrap(trace.samples.first)
        XCTAssertEqual(sample.durationMilliseconds, 1)
        XCTAssertEqual(sample.phase, .libraryDecodeApply)
        XCTAssertEqual(sample.outcome, .completed)
        let encoded = try JSONEncoder().encode(sample)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(fields["durationKind"] as? String, "inclusive_synchronous_scope")
        XCTAssertEqual(fields["durationMilliseconds"] as? Double, 1)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("private operation result"))
    }

    func testNestedIntervalsOverlapAndHaveDistinctIdentity() throws {
        let trace = StartupTraceCapture()
        let timing = trace.recorder()
        timing.measure(.macDelegateCreation) {
            timing.measure(.libraryDecodeApply) { }
        }
        let inner = try XCTUnwrap(trace.samples.first)
        let outer = try XCTUnwrap(trace.samples.last)
        XCTAssertEqual(inner.durationMilliseconds, 1)
        XCTAssertEqual(outer.durationMilliseconds, 3)
        XCTAssertLessThan(outer.startedAtNanoseconds, inner.startedAtNanoseconds)
        XCTAssertGreaterThan(outer.endedAtNanoseconds, inner.endedAtNanoseconds)
        XCTAssertEqual(inner.traceID, outer.traceID)
        XCTAssertNotEqual(inner.spanID, outer.spanID)
    }

    func testFailureAndCancellationAreRecordedWithoutReplacingTheError() {
        let trace = StartupTraceCapture()
        let timing = trace.recorder()
        let expected = NSError(domain: "StartupFixture", code: 17)
        do {
            let _: Void = try timing.measure(.macWindowSetup) { throw expected }
            XCTFail("The original error must propagate")
        } catch { XCTAssertTrue((error as NSError) === expected) }
        XCTAssertThrowsError(try timing.measure(.macWindowSetup) { throw CancellationError() }) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(trace.samples.map(\.outcome), [.failed, .cancelled])
    }

    func testConcurrentScopesKeepUniqueIdentityAndIndependentTraces() {
        let trace = StartupTraceCapture()
        let timing = trace.recorder()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in timing.measure(.libraryDecodeApply) { } }
        XCTAssertEqual(Set(trace.samples.map(\.spanID)).count, 32)
        XCTAssertEqual(Set(trace.samples.map(\.traceID)).count, 1)
        trace.recorder().measure(.libraryDecodeApply) { }
        XCTAssertEqual(Set(trace.samples.map(\.traceID)).count, 2)
    }

    func testSharedRecorderFollowsTheActualProcessArgument() {
        XCTAssertEqual(AppStartupTiming.shared.isEnabled, ProcessInfo.processInfo.arguments.contains("-measureStartup"))
    }

    @MainActor
    func testLibraryDecodeUsesInjectedTimingWithoutChangingPersistedIndex() throws {
        let name = "StartupLibrary.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let original = Data("[]".utf8)
        defaults.set(original, forKey: "library")
        let trace = StartupTraceCapture()
        let store = LibraryStore(defaults: defaults, defaultsKey: "library", startupTiming: trace.recorder())
        XCTAssertTrue(store.books.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "library"), original)
        XCTAssertEqual(trace.samples.map(\.phase), [.libraryDecodeApply])
    }

    #if os(macOS)
    @MainActor
    func testOptInVisibleShippingWindowSetupEmitsDiagnostics() async throws {
        guard ProcessInfo.processInfo.environment["EPUB_STARTUP_GUI_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in startup setup diagnostics acceptance")
        }
        XCTAssertTrue(AppStartupTiming.shared.isEnabled)
        let name = "StartupWindow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let keys = [ReaderSessionState.currentlyReadingBookIDKey, AudioPlayer.currentBookIDDefaultsKey, "readerWarmBookIDs.v1"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let setup = MacApplicationWindowSetup.make(settings: AppSettings(defaults: defaults),
            library: LibraryStore(defaults: defaults, defaultsKey: "library"), player: player,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            playerPresentation: PlayerPresentation(defaults: defaults))
        setup.window.isReleasedWhenClosed = false
        defer {
            LocalFulltextCache.cancelPrewarming()
            player.stop()
            setup.window.orderOut(nil); setup.window.contentViewController = nil; setup.window.close()
            for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: name)
            NSApp.setActivationPolicy(policy)
        }
        let activation = NSWorkspace.OpenConfiguration()
        activation.activates = true; activation.createsNewApplicationInstance = false
        let running = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: activation)
        XCTAssertEqual(running.processIdentifier, ProcessInfo.processInfo.processIdentifier)
        setup.window.makeKeyAndOrderFront(nil)
        setup.root.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(setup.window.contentViewController === setup.root)
        XCTAssertTrue(setup.root.view.window === setup.window)
        XCTAssertTrue(setup.window.isVisible)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, ProcessInfo.processInfo.processIdentifier)
        let content = try XCTUnwrap(setup.window.contentView)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                       uniformTypeIdentifier: "public.png")
        attachment.name = "visible-startup-setup-diagnostics"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    #endif
}

private final class StartupTraceCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var tick: UInt64 = 0
    private var captured: [AppStartupTiming.Sample] = []
    var clockReads: UInt64 { lock.withLock { tick } }
    var samples: [AppStartupTiming.Sample] { lock.withLock { captured } }

    func recorder(arguments: [String] = ["app", "-measureStartup"]) -> AppStartupTiming {
        AppStartupTiming(arguments: arguments, clock: {
            self.lock.withLock { self.tick += 1; return self.tick * 1_000_000 }
        }, sink: { sample in self.lock.withLock { self.captured.append(sample) } })
    }
}
