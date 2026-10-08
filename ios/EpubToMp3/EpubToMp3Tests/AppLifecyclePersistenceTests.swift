import Foundation
import XCTest
#if os(iOS)
import UIKit
#else
import AppKit
#endif
@testable import EpubToMp3

private final class LifecycleEncodingGate: @unchecked Sendable {
    let entered: XCTestExpectation
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var finished = false

    init(entered: XCTestExpectation) { self.entered = entered }

    var didFinish: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    func unblock() { release.signal() }

    func encode(_ books: [BookEntity]) throws -> Data {
        entered.fulfill()
        guard release.wait(timeout: .now() + 5) == .success else {
            throw NSError(domain: "AppLifecyclePersistenceTests", code: 1)
        }
        let data = try JSONEncoder().encode(books)
        lock.lock(); finished = true; lock.unlock()
        return data
    }
}

final class AppLifecyclePersistenceTests: XCTestCase {
    @MainActor
    private func withIsolatedLibrary(
        _ body: (LibraryStore, UserDefaults, LifecycleEncodingGate) async throws -> Void
    ) async throws {
        let suite = "app.lifecycle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let book = BookEntity(id: suite, title: "Before lifecycle", bookmark: Data([1]),
                              displayFilename: "Isolated.epub", addedAt: .now)
        defaults.set(try JSONEncoder().encode([book]), forKey: "library.books.v1")
        let gate = LifecycleEncodingGate(entered: expectation(description: "Pending index encoding"))
        let store = LibraryStore(defaults: defaults, importDirectory: root,
                                 indexEncoder: { try gate.encode($0) })
        defer {
            gate.unblock()
            try? store.flushPersistenceSync()
        }
        var updated = book
        updated.title = "Persisted by lifecycle"
        store.update(updated)
        await fulfillment(of: [gate.entered], timeout: 2)
        XCTAssertEqual(LibraryStore(defaults: defaults, importDirectory: root).books.first?.title,
                       "Before lifecycle")
        try await body(store, defaults, gate)
    }

    @MainActor
    func testTerminationWaitsForPendingLibraryPersistence() async throws {
        try await withIsolatedLibrary { store, defaults, gate in
            let app = EpubToMp3App(library: store)
            // The encoder cannot finish until after the synchronous callback starts.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { gate.unblock() }
#if os(iOS)
            app.applicationWillTerminate(UIApplication.shared)
#else
            app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
#endif
            XCTAssertTrue(gate.didFinish, "Termination must wait for the queued encoder")
            let data = try XCTUnwrap(defaults.data(forKey: "library.books.v1"))
            XCTAssertEqual(try JSONDecoder().decode([BookEntity].self, from: data).first?.title,
                           "Persisted by lifecycle")
        }
    }

#if os(iOS)
    @MainActor
    func testExpiredGenerationCannotEndReplacementBackgroundGrant() async throws {
        try await withIsolatedLibrary { store, defaults, gate in
            let app = EpubToMp3App(library: store)
            let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
            defer {
                UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
                if let state = app.libraryPersistenceBackgroundState {
                    app.endLibraryPersistenceWindow(generation: state.generation)
                }
            }
            app.applicationDidEnterBackground(UIApplication.shared)
            let first = try XCTUnwrap(app.libraryPersistenceBackgroundState)
            XCTAssertNotEqual(first.identifier, .invalid)
            XCTAssertFalse(gate.didFinish)

            // Exercise the same generation-checked path as the expiration handler.
            app.endLibraryPersistenceWindow(generation: first.generation)
            XCTAssertNil(app.libraryPersistenceBackgroundState)
            XCTAssertFalse(gate.didFinish, "Expiration must not wait for the encoder")

            app.applicationDidEnterBackground(UIApplication.shared)
            let replacement = try XCTUnwrap(app.libraryPersistenceBackgroundState)
            XCTAssertNotEqual(replacement.identifier, .invalid)
            XCTAssertNotEqual(replacement.generation, first.generation)
            app.endLibraryPersistenceWindow(generation: first.generation)
            XCTAssertEqual(app.libraryPersistenceBackgroundState?.generation, replacement.generation)
            XCTAssertEqual(app.libraryPersistenceBackgroundState?.identifier, replacement.identifier)
            XCTAssertFalse(gate.didFinish)

            gate.unblock()
            let ended = expectation(description: "Replacement grant ends after persistence")
            Task { @MainActor in
                for _ in 0..<200 {
                    if app.libraryPersistenceBackgroundState == nil {
                        ended.fulfill()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            await fulfillment(of: [ended], timeout: 3)
            XCTAssertNil(app.libraryPersistenceBackgroundState)
            XCTAssertTrue(gate.didFinish)
            let data = try XCTUnwrap(defaults.data(forKey: "library.books.v1"))
            XCTAssertEqual(try JSONDecoder().decode([BookEntity].self, from: data).first?.title,
                           "Persisted by lifecycle")
        }
    }

    @MainActor
    func testBackgroundGrantEndsAfterPendingLibraryPersistence() async throws {
        try await withIsolatedLibrary { store, defaults, gate in
            let app = EpubToMp3App(library: store)
            let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
            defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
            app.applicationDidEnterBackground(UIApplication.shared)
            let first = try XCTUnwrap(app.libraryPersistenceBackgroundState)
            XCTAssertNotEqual(first.identifier, .invalid, "A real background grant is required")
            app.deactivateRuntimeForScene()
            XCTAssertEqual(app.libraryPersistenceBackgroundState?.generation, first.generation)
            XCTAssertFalse(gate.didFinish)
            gate.unblock()

            let ended = expectation(description: "Lifecycle ends its background grant")
            Task { @MainActor in
                for _ in 0..<200 {
                    if app.libraryPersistenceBackgroundState == nil {
                        ended.fulfill()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            await fulfillment(of: [ended], timeout: 3)
            XCTAssertNil(app.libraryPersistenceBackgroundState)
            XCTAssertTrue(gate.didFinish)
            let data = try XCTUnwrap(defaults.data(forKey: "library.books.v1"))
            XCTAssertEqual(try JSONDecoder().decode([BookEntity].self, from: data).first?.title,
                           "Persisted by lifecycle")
        }
    }
#endif
}
