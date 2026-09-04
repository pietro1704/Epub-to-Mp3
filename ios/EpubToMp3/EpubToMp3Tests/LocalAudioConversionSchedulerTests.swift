import XCTest
@testable import EpubToMp3

final class LocalAudioConversionSchedulerTests: XCTestCase {
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                if isOpen {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    func testRunsDifferentBooksInFirstInFirstOutOrder() async throws {
        let scheduler = LocalAudioConversionScheduler(
            initialConnectivity: .wifi,
            observesNetwork: false
        )
        let gate = Gate()
        var started: [String] = []

        let first = Task { @MainActor in
            try await scheduler.submit(bookID: "first", requiresWiFi: true, coalescingKey: "test") {
                started.append("first")
                await gate.wait()
                return self.snapshot(jobID: "first")
            }
        }
        await Task.yield()
        let second = Task { @MainActor in
            try await scheduler.submit(bookID: "second", requiresWiFi: true, coalescingKey: "test") {
                started.append("second")
                return self.snapshot(jobID: "second")
            }
        }
        await Task.yield()

        XCTAssertEqual(started, ["first"])
        await gate.open()
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(started, ["first", "second"])
    }

    @MainActor
    func testWiFiOnlyWorkWaitsForWiFiAndResumesWithoutCancellation() async throws {
        let scheduler = LocalAudioConversionScheduler(
            initialConnectivity: .cellular,
            observesNetwork: false
        )
        var didRun = false

        let task = Task { @MainActor in
            try await scheduler.submit(bookID: "book", requiresWiFi: true, coalescingKey: "test") {
                didRun = true
                return self.snapshot(jobID: "book")
            }
        }
        await Task.yield()

        XCTAssertEqual(scheduler.state(for: "book"), .waitingForWiFi)
        XCTAssertFalse(didRun)

        scheduler.setConnectivity(.wifi)
        _ = try await task.value
        XCTAssertTrue(didRun)
        XCTAssertEqual(scheduler.state(for: "book"), .finished)
    }

    @MainActor
    func testAllowingCellularResumesWaitingWorkAtTheNextChapterBoundary() async throws {
        let scheduler = LocalAudioConversionScheduler(
            initialConnectivity: .cellular,
            observesNetwork: false
        )
        var didRun = false

        let task = Task { @MainActor in
            try await scheduler.submit(bookID: "book", requiresWiFi: true, coalescingKey: "test") {
                didRun = true
                return self.snapshot(jobID: "book")
            }
        }
        await Task.yield()
        XCTAssertEqual(scheduler.state(for: "book"), .waitingForWiFi)

        scheduler.setAllowsCellularConversion(true)
        let snapshot = try await task.value

        XCTAssertTrue(didRun)
        XCTAssertEqual(snapshot.jobId, "book")
        XCTAssertEqual(scheduler.state(for: "book"), .finished)
    }

    @MainActor
    func testResourcePressureYieldsAtBoundaryAndResumesTheSameWork() async throws {
        let scheduler = LocalAudioConversionScheduler(
            initialConnectivity: .wifi,
            observesNetwork: false
        )
        scheduler.setResourceConstraint(.thermalPressure)
        var resumed = false

        let task = Task { @MainActor in
            try await scheduler.submit(bookID: "book", requiresWiFi: true, coalescingKey: "test") {
                await scheduler.waitForResourceStability(bookID: "book")
                resumed = true
                return self.snapshot(jobID: "book")
            }
        }
        await Task.yield()

        XCTAssertEqual(scheduler.state(for: "book"), .waitingForResources)
        XCTAssertFalse(resumed)
        scheduler.setResourceConstraint(.stable)
        _ = try await task.value
        XCTAssertTrue(resumed)
        XCTAssertEqual(scheduler.state(for: "book"), .finished)
    }

    @MainActor
    func testMemoryPressureYieldsAtBoundaryUntilTheQuietWindowEnds() async throws {
        let scheduler = LocalAudioConversionScheduler(
            initialConnectivity: .wifi,
            observesNetwork: false
        )
        scheduler.reportMemoryPressure(recoveryDelay: 60)
        var resumed = false

        let task = Task { @MainActor in
            try await scheduler.submit(bookID: "book", requiresWiFi: true, coalescingKey: "test") {
                await scheduler.waitForResourceStability(bookID: "book")
                resumed = true
                return self.snapshot(jobID: "book")
            }
        }
        await Task.yield()

        XCTAssertEqual(scheduler.state(for: "book"), .waitingForResources)
        XCTAssertFalse(resumed)
        scheduler.setResourceConstraint(.stable)
        _ = try await task.value
        XCTAssertTrue(resumed)
        XCTAssertEqual(scheduler.state(for: "book"), .finished)
    }

    @MainActor
    func testPriorityChapterIsSelectedBeforeNormalBookOrder() {
        let scheduler = LocalAudioConversionScheduler(
            initialConnectivity: .wifi,
            observesNetwork: false
        )

        scheduler.prioritize(bookID: "book", chapterIndices: [3, 1, 3])

        XCTAssertEqual(
            scheduler.nextChapterIndex(
                bookID: "book",
                available: [0, 1, 2, 3],
                defaultOrder: [0, 1, 2, 3]
            ),
            3
        )
        XCTAssertEqual(
            scheduler.nextChapterIndex(
                bookID: "book",
                available: [0, 1, 2],
                defaultOrder: [0, 1, 2]
            ),
            1
        )
    }

    @MainActor
    func testPriorityAddedForAQueuedSameBookJobSurvivesThePreviousJobFinishing() async throws {
        let scheduler = LocalAudioConversionScheduler(
            initialConnectivity: .wifi,
            observesNetwork: false
        )
        let gate = Gate()
        var nextChapter: Int?

        let first = Task { @MainActor in
            try await scheduler.submit(bookID: "book", requiresWiFi: true, coalescingKey: "chapter") {
                await gate.wait()
                return self.snapshot(jobID: "first")
            }
        }
        await Task.yield()

        let second = Task { @MainActor in
            try await scheduler.submit(
                bookID: "book",
                requiresWiFi: true,
                priorityChapterIndices: [3],
                coalescingKey: "listen"
            ) {
                nextChapter = scheduler.nextChapterIndex(
                    bookID: "book",
                    available: [0, 1, 2, 3],
                    defaultOrder: [0, 1, 2, 3]
                )
                return self.snapshot(jobID: "second")
            }
        }
        await Task.yield()

        await gate.open()
        _ = try await first.value
        _ = try await second.value

        XCTAssertEqual(nextChapter, 3)
    }

    @MainActor
    func testPendingWorkKeepsActiveThenQueuedFIFOOrderAfterSchedulerRecreation() async throws {
        let suiteName = "LocalAudioConversionSchedulerTests.\(UUID().uuidString)"
        guard let persistence = UserDefaults(suiteName: suiteName) else {
            return XCTFail("The isolated persistence suite could not be created.")
        }
        defer { persistence.removePersistentDomain(forName: suiteName) }

        let request = LocalAudioConversionScheduler.ResumeRequest(
            bookID: "book-id",
            coalescingKey: "download",
            requiresWiFi: true,
            priorityChapterIndices: [4],
            requestedChapterIndices: [4],
            engine: "edge",
            voice: "en-US-AvaMultilingualNeural",
            language: "en",
            clearCache: false,
            forceReprocess: false,
            maxPerformance: false
        )
        let scheduler = LocalAudioConversionScheduler(
            initialConnectivity: .wifi,
            observesNetwork: false,
            persistence: persistence
        )
        let gate = Gate()
        let task = Task { @MainActor in
            try await scheduler.submit(
                bookID: request.bookID,
                requiresWiFi: request.requiresWiFi,
                priorityChapterIndices: request.priorityChapterIndices,
                coalescingKey: request.coalescingKey,
                resumeRequest: request
            ) {
                await gate.wait()
                return self.snapshot(jobID: request.bookID)
            }
        }
        await Task.yield()

        let secondRequest = LocalAudioConversionScheduler.ResumeRequest(
            bookID: "second-book-id",
            coalescingKey: "download",
            requiresWiFi: true,
            priorityChapterIndices: [],
            requestedChapterIndices: nil,
            engine: "edge",
            voice: "en-US-AvaMultilingualNeural",
            language: "en",
            clearCache: false,
            forceReprocess: false,
            maxPerformance: false
        )
        let secondTask = Task { @MainActor in
            try await scheduler.submit(
                bookID: secondRequest.bookID,
                requiresWiFi: secondRequest.requiresWiFi,
                coalescingKey: secondRequest.coalescingKey,
                resumeRequest: secondRequest
            ) {
                self.snapshot(jobID: secondRequest.bookID)
            }
        }
        await Task.yield()

        let restoredScheduler = LocalAudioConversionScheduler(
            initialConnectivity: .wifi,
            observesNetwork: false,
            persistence: persistence
        )
        XCTAssertEqual(
            restoredScheduler.pendingResumeRequests().map(\.bookID),
            [request.bookID, secondRequest.bookID]
        )

        await gate.open()
        _ = try await task.value
        _ = try await secondTask.value
    }

    @MainActor
    func testHandledCacheActionIsNotRepeatedAfterSchedulerRestoration() async throws {
        let suiteName = "LocalAudioConversionSchedulerTests.\(UUID().uuidString)"
        guard let persistence = UserDefaults(suiteName: suiteName) else {
            return XCTFail("The isolated persistence suite could not be created.")
        }
        defer { persistence.removePersistentDomain(forName: suiteName) }

        let request = LocalAudioConversionScheduler.ResumeRequest(
            bookID: "book-id",
            coalescingKey: "download",
            requiresWiFi: true,
            priorityChapterIndices: [],
            requestedChapterIndices: nil,
            engine: "edge",
            voice: "voice",
            language: nil,
            clearCache: true,
            forceReprocess: true,
            maxPerformance: false
        )
        let scheduler = LocalAudioConversionScheduler(
            initialConnectivity: .wifi,
            observesNetwork: false,
            persistence: persistence
        )
        let gate = Gate()
        let task = Task { @MainActor in
            try await scheduler.submit(
                bookID: request.bookID,
                requiresWiFi: request.requiresWiFi,
                coalescingKey: request.coalescingKey,
                resumeRequest: request
            ) {
                await gate.wait()
                return self.snapshot(jobID: request.bookID)
            }
        }
        await Task.yield()

        scheduler.markInitialCacheActionHandled(bookID: request.bookID)
        let restoredScheduler = LocalAudioConversionScheduler(
            initialConnectivity: .wifi,
            observesNetwork: false,
            persistence: persistence
        )
        let restored = try XCTUnwrap(restoredScheduler.pendingResumeRequests().first)
        XCTAssertFalse(restored.clearCache)
        XCTAssertFalse(restored.forceReprocess)

        await gate.open()
        _ = try await task.value
    }

    private func snapshot(jobID: String) -> JobSnapshot {
        JobSnapshot(
            jobId: jobID,
            state: "finished",
            bookTitle: "Book",
            bookAuthor: nil,
            coverUrl: nil,
            coverMimeType: nil,
            engine: "edge",
            voice: nil,
            language: nil,
            progressPercent: 100,
            chaptersTotal: 0,
            chaptersCompleted: 0,
            chapterProgress: [],
            outputs: nil,
            logUrl: nil,
            error: nil,
            lastActivityAt: nil
        )
    }
}
