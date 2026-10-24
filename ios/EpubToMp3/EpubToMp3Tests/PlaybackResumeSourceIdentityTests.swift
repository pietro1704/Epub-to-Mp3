import XCTest
@testable import EpubToMp3

@MainActor
final class PlaybackResumeSourceIdentityTests: XCTestCase {
    func testPartialQueueAndSegmentsPersistSourceIdentityInsteadOfQueueOffset() throws {
        let snapshot = try JSONDecoder().decode(JobSnapshot.self, from: Data(
            #"{"jobId":"fixture","state":"running","chapterProgress":[{"index":16,"status":"completed","downloadUrl":"/fixture/ch16.mp3"},{"index":18,"status":"completed","downloadUrl":"/fixture/ch18.mp3"}]}"#.utf8))
        XCTAssertEqual(PlaybackResumeStore.sourceChapterIndex(snapshot: snapshot, playbackChapters: [],
            queueOffset: 0, segmentMode: false, segmentChapterIndex: -1), 16)
        XCTAssertEqual(PlaybackResumeStore.sourceChapterIndex(snapshot: snapshot, playbackChapters: [],
            queueOffset: 1, segmentMode: false, segmentChapterIndex: -1), 18)
        XCTAssertEqual(PlaybackResumeStore.sourceChapterIndex(snapshot: snapshot, playbackChapters: [],
            queueOffset: 2, segmentMode: true, segmentChapterIndex: 16), 16)
        XCTAssertNil(PlaybackResumeStore.sourceChapterIndex(snapshot: snapshot, playbackChapters: [],
            queueOffset: 0, segmentMode: true, segmentChapterIndex: -1))
    }

    func testUnresolvedOrCancelledPendingSnapshotCannotOverwriteSavedChapter() throws {
        let suite = "ResumeSource.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = PlaybackResumeStore.currentChapterIndexDefaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set(16, forKey: key)
        let store = PlaybackResumeStore(store: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let pending = try JSONDecoder().decode(JobSnapshot.self, from: Data(
            #"{"jobId":"replacement","state":"running","chapterProgress":[]}"#.utf8))
        XCTAssertNil(PlaybackResumeStore.sourceChapterIndex(snapshot: pending, playbackChapters: [],
            queueOffset: 0, segmentMode: false, segmentChapterIndex: -1))
        store.persist(snapshot: pending, chapterIndex: 0, sourceChapterIndex: nil,
            positionSeconds: 0, isPlaying: false, force: true)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: key), 16)
        store.persist(snapshot: pending, chapterIndex: 2, sourceChapterIndex: 18,
            positionSeconds: 42, isPlaying: false, force: true)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: key), 18)
        XCTAssertEqual(store.marker(jobId: "replacement", chapterIndex: 2)?.positionSeconds, 42)
        store.persist(snapshot: nil, chapterIndex: 0, sourceChapterIndex: 0,
            positionSeconds: 0, isPlaying: false, force: true)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: key), 18)
    }
}
