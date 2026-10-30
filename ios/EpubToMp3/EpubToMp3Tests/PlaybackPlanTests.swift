#if canImport(AVFoundation) && canImport(MediaPlayer)
import AVFoundation
import Foundation
import XCTest
@testable import EpubToMp3

final class PlaybackPlanTests: XCTestCase {
    private func snapshot(_ chapters: [JobSnapshot.Chapter], state: String = "running") -> JobSnapshot {
        JobSnapshot(jobId: "book", state: state, bookTitle: "Fixture", bookAuthor: nil,
                    coverUrl: nil, coverMimeType: nil, engine: nil, voice: nil, language: "en",
                    progressPercent: nil, chaptersTotal: chapters.count, chaptersCompleted: nil,
                    chapterProgress: chapters, outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
    }
    private func chapter(_ index: Int, url: URL? = nil) -> JobSnapshot.Chapter {
        .init(index: index, name: "Chapter \(index)", status: url == nil ? "pending" : "completed",
              downloadUrl: url?.absoluteString, chars: nil, charsProcessed: nil, progressRatio: nil,
              durationSeconds: nil, startedAt: nil, completedAt: nil)
    }

    func testSpeechRouteKeepsPlayableIdentityAndOnlyTrimsFallbackText() {
        let requested = snapshot([chapter(3), chapter(7, url: URL(fileURLWithPath: "/seven.wav"))])
        guard case .audio(let selected, let offset) = SpeechPlaybackRoute.plan(
            snapshot: requested, chapterIndex: 7, chapterText: "  ignored  ") else {
            return XCTFail("A playable requested chapter remains primary")
        }
        XCTAssertEqual(selected.jobId, requested.jobId)
        XCTAssertEqual(offset, 0)
        guard case .speech(let text) = SpeechPlaybackRoute.plan(
            snapshot: requested, chapterIndex: 3, chapterText: "  spoken text \n") else {
            return XCTFail("Other playable chapters cannot replace the requested chapter")
        }
        XCTAssertEqual(text, "spoken text")
        guard case .unavailable = SpeechPlaybackRoute.plan(snapshot: nil, chapterIndex: 3, chapterText: " \n") else {
            return XCTFail("Whitespace cannot grant a speech route")
        }
    }

    @MainActor
    func testReaderSentencePlanUsesPlayableOffsetAndBoundedTimingIdentity() {
        let reader = ReaderPlaybackSeek()
        let navigation = ChapterNavigationDecision()
        let segments = PlaybackSegmentSession()
        let state = snapshot([chapter(5, url: URL(fileURLWithPath: "/five.wav")),
                              chapter(9, url: URL(fileURLWithPath: "/nine.wav"))])
        reader.setTiming(["sentence": 1000, "following": 3000], forChapterIndex: 1)
        let plan = reader.plan(chapter: 9, sentenceID: "sentence", ratio: 0.9, wordRatio: 0.5,
                               snapshot: state, hasPlayer: true, segmentMode: false,
                               segments: segments, navigation: navigation)
        guard case .chapter(let offset, .sentence(let position)) = plan else {
            return XCTFail("Precise sentence timing must win over proportional position")
        }
        XCTAssertEqual(offset, 1)
        XCTAssertEqual(position, 2)
        for index in 2...9 { reader.setTiming(["new": index], forChapterIndex: index) }
        XCTAssertNil(reader.timingMap(for: 1))
        XCTAssertNotNil(reader.timingMap(for: 9))
        reader.setTiming([:], forChapterIndex: 9)
        XCTAssertNil(reader.timingMap(for: 9))
    }

    @MainActor
    func testReaderPendingPlanRetainsBookIdentityAndRejectsNonfiniteRatio() {
        let reader = ReaderPlaybackSeek()
        let plan = reader.plan(chapter: 7, sentenceID: nil, ratio: .infinity, wordRatio: nil,
                               snapshot: snapshot([chapter(7)]), hasPlayer: false, segmentMode: false,
                               segments: PlaybackSegmentSession(), navigation: ChapterNavigationDecision())
        guard case .pending(let request, let waiting) = plan else {
            return XCTFail("A requested page must remain pending before the first file")
        }
        XCTAssertTrue(waiting)
        XCTAssertEqual(request.jobID, "book")
        XCTAssertEqual(request.chapterIndex, 7)
        XCTAssertTrue(request.autoplay)
        XCTAssertNil(request.readerPageRatio)
        let absent = reader.plan(chapter: 7, sentenceID: nil, ratio: 0.2, wordRatio: nil,
                                 snapshot: nil, hasPlayer: false, segmentMode: false,
                                 segments: PlaybackSegmentSession(), navigation: ChapterNavigationDecision())
        guard case .resume = absent else { return XCTFail("Missing snapshot preserves the resume command") }
    }

    @MainActor
    func testChapterSessionAppendsByIdentityAndReplacesOnlyFutureItems() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(buffer.frameLength) { samples[frame] = 0 }
        do {
            let file = try AVAudioFile(forWriting: firstURL, settings: format.settings)
            try file.write(from: buffer)
        }
        let secondURL = directory.appendingPathComponent("second.wav")
        let replacementURL = directory.appendingPathComponent("replacement.wav")
        let earlierURL = directory.appendingPathComponent("earlier.wav")
        for url in [secondURL, replacementURL, earlierURL] { try FileManager.default.copyItem(at: firstURL, to: url) }
        let session = PlaybackChapterSession()
        let queueSession = PlaybackQueueSession()
        defer { queueSession.teardown() }
        let original = snapshot([chapter(5, url: firstURL), chapter(6, url: secondURL)])
        let queue = try XCTUnwrap(session.install(snapshot: original, startingAt: 0, queueSession: queueSession,
                                                  resolveURL: { path, _, _ in path.flatMap { URL(string: $0) } }))
        let firstItem = try XCTUnwrap(queue.currentItem)
        let oldFuture = try XCTUnwrap(queue.items().last)
        let replaced = snapshot([chapter(5, url: firstURL), chapter(6, url: replacementURL)])
        session.reconcile(previousSnapshot: original, newSnapshot: replaced, currentChapterIndex: 0,
                          queue: queue, queueSession: queueSession, resolveURL: { path, _, _ in path.flatMap { URL(string: $0) } })
        XCTAssertTrue(queue.currentItem === firstItem)
        XCTAssertFalse(queueSession.owns(ObjectIdentifier(oldFuture)))
        XCTAssertEqual((queue.items().last?.asset as? AVURLAsset)?.url, replacementURL)
        let wrapped = snapshot([chapter(1, url: earlierURL), chapter(5, url: firstURL), chapter(6, url: replacementURL)])
        session.reconcile(previousSnapshot: replaced, newSnapshot: wrapped, currentChapterIndex: 0,
                          queue: queue, queueSession: queueSession, resolveURL: { path, _, _ in path.flatMap { URL(string: $0) } })
        XCTAssertEqual(session.chapters.map(\.index), [5, 6, 1])
        XCTAssertTrue(queue.currentItem === firstItem)
        XCTAssertEqual(queue.items().count, 3)
        XCTAssertEqual((queue.items().last?.asset as? AVURLAsset)?.url, earlierURL)
    }

    @MainActor
    func testChapterSessionWaitsForRequestedStartWithoutCreatingQueue() {
        let session = PlaybackChapterSession()
        let queue = PlaybackQueueSession()
        let loaded = session.install(snapshot: snapshot([chapter(2)]), startingAt: 4, queueSession: queue,
                                     resolveURL: { _, _, _ in XCTFail("No file may be resolved before it exists"); return nil })
        XCTAssertNil(loaded)
        XCTAssertNil(queue.player)
        XCTAssertEqual(session.pendingStartIndex, 4)
        XCTAssertTrue(session.chapters.isEmpty)
    }
    @MainActor
    func testFullFileHandoffPreservesRequestIdentityAndPauseIntent() {
        let pending = PendingPlaybackSeek { _ in }
        let id = UUID()
        pending.chapter = .init(id: id, jobID: "book", chapterIndex: 7, autoplay: false, position: 13)
        let completed = snapshot([chapter(8, url: URL(fileURLWithPath: "/eight.wav"))], state: "finished")
        guard case .ready(let offset, let request) = pending.fullFileHandoff(snapshot: completed, segmentMode: true) else {
            return XCTFail("A one-based full-file manifest must resolve the pending segment identity")
        }
        XCTAssertEqual(offset, 0)
        XCTAssertEqual(request.id, id)
        XCTAssertEqual(request.chapterIndex, 8)
        XCTAssertFalse(request.autoplay)
        XCTAssertEqual(request.position, 13)
        XCTAssertEqual(pending.chapter?.chapterIndex, 7, "Planning must not commit a transport change")
        guard case .waiting(let terminal) = pending.fullFileHandoff(snapshot: snapshot([], state: "finished"), segmentMode: true) else {
            return XCTFail("A terminal missing target must remain distinguishable from another book")
        }
        XCTAssertTrue(terminal)
        pending.chapter = .init(id: UUID(), jobID: "other", chapterIndex: 7, autoplay: true)
        guard case .unrelated = pending.fullFileHandoff(snapshot: completed, segmentMode: true) else {
            return XCTFail("A different book cannot reuse this pending request")
        }
    }

    @MainActor
    func testApproximateFullFileHandoffUsesTheCompletedFilesOwnTimeOrigin() {
        let pending = PendingPlaybackSeek { _ in }
        let completed = snapshot([chapter(1, url: URL(fileURLWithPath: "/suffix.wav"))], state: "finished")
        for installedSuffix in [false, true] {
            let id = UUID()
            pending.chapter = .init(id: id, jobID: "book", chapterIndex: 0, autoplay: false,
                position: 150, startsAtGeneratedOrigin: installedSuffix, navigationTarget: .approximateTime(0.5))
            guard case .ready(_, let request) = pending.fullFileHandoff(snapshot: completed, segmentMode: true) else {
                return XCTFail("A completed file must settle the pending navigation")
            }
            XCTAssertEqual(request.id, id)
            XCTAssertFalse(request.autoplay)
            XCTAssertEqual(request.position, installedSuffix ? 0 : 150)
            XCTAssertEqual(request.navigationTarget, .chapterTime(installedSuffix ? 0 : 150))
        }
    }

    @MainActor
    func testNavigationPlanUsesCanonicalSparseChapterIdentity() {
        let state = snapshot([chapter(0), chapter(8)])
        guard case .segment(let chapter) = PlaybackChapterQueue.navigation(direction: .forward,
            snapshot: state, chapters: [], currentIndex: 0, position: 0, segmentMode: true, hasPlayer: true) else {
            return XCTFail("Progressive navigation must choose the next source chapter")
        }
        XCTAssertEqual(chapter, 8)
        guard case .seekStart = PlaybackChapterQueue.navigation(direction: .backward,
            snapshot: state, chapters: [], currentIndex: 8, position: 4, segmentMode: true, hasPlayer: true) else {
            return XCTFail("Previous restarts a chapter after three seconds")
        }
        guard case .none = PlaybackChapterQueue.navigation(direction: .forward,
            snapshot: state, chapters: [], currentIndex: 8, position: 0, segmentMode: true, hasPlayer: true) else {
            return XCTFail("The last chapter has no forward destination")
        }
    }

}
#endif
