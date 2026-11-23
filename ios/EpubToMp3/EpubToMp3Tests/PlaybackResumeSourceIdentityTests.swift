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

    func testResumeLocationAndMarkersRemainInTheirInjectedSuitesAcrossReopen() throws {
        let a = "LocationA.\(UUID().uuidString)", b = "LocationB.\(UUID().uuidString)"
        let defaultsA = try XCTUnwrap(UserDefaults(suiteName: a))
        let defaultsB = try XCTUnwrap(UserDefaults(suiteName: b))
        defer {
            defaultsA.removePersistentDomain(forName: a)
            defaultsB.removePersistentDomain(forName: b)
        }
        let key = "currentlyPlayingChapterIndex"
        let standardChapter = UserDefaults.standard.object(forKey: key) as? Int
        let snapshot = try JSONDecoder().decode(JobSnapshot.self, from: Data(
            #"{"jobId":"shared-job","state":"running","chapterProgress":[]}"#.utf8))
        func store(_ defaults: UserDefaults) -> PlaybackResumeStore {
            AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults))).services.resume
        }
        defaultsB.set(0, forKey: key)
        XCTAssertNil(defaultsA.object(forKey: key))
        store(defaultsA).persist(snapshot: snapshot, chapterIndex: 2, sourceChapterIndex: 18,
                                 positionSeconds: 42, isPlaying: false, force: true)
        XCTAssertEqual(store(defaultsA).marker(jobId: snapshot.jobId, chapterIndex: 2)?.positionSeconds, 42)
        XCTAssertEqual(defaultsA.object(forKey: key) as? Int, 18)
        XCTAssertNil(store(defaultsB).marker(jobId: snapshot.jobId, chapterIndex: 2))
        XCTAssertEqual(defaultsB.object(forKey: key) as? Int, 0)
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Int, standardChapter)
    }

    func testUnresolvedOrCancelledPendingSnapshotCannotOverwriteSavedChapter() throws {
        let suite = "ResumeSource.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = PlaybackResumeStore.currentChapterIndexDefaultsKey
        defaults.set(16, forKey: key)
        let store = PlaybackResumeStore(store: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)),
                                        location: ReaderLocation(defaults: defaults))
        let pending = try JSONDecoder().decode(JobSnapshot.self, from: Data(
            #"{"jobId":"replacement","state":"running","chapterProgress":[]}"#.utf8))
        XCTAssertNil(PlaybackResumeStore.sourceChapterIndex(snapshot: pending, playbackChapters: [],
            queueOffset: 0, segmentMode: false, segmentChapterIndex: -1))
        store.persist(snapshot: pending, chapterIndex: 0, sourceChapterIndex: nil,
            positionSeconds: 0, isPlaying: false, force: true)
        XCTAssertEqual(defaults.integer(forKey: key), 16)
        store.persist(snapshot: pending, chapterIndex: 2, sourceChapterIndex: 18,
            positionSeconds: 42, isPlaying: false, force: true)
        XCTAssertEqual(defaults.integer(forKey: key), 18)
        XCTAssertEqual(store.marker(jobId: "replacement", chapterIndex: 2)?.positionSeconds, 42)
        store.persist(snapshot: nil, chapterIndex: 0, sourceChapterIndex: 0,
            positionSeconds: 0, isPlaying: false, force: true)
        XCTAssertEqual(defaults.integer(forKey: key), 18)
    }

    func testUnforcedResumeWritesAreThrottledAndForcedWritesAreNot() throws {
        let suite = "ResumeThrottle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackResumeStore(store: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)),
                                        location: ReaderLocation(defaults: defaults))
        let snapshot = try JSONDecoder().decode(JobSnapshot.self, from: Data(
            #"{"jobId":"throttle","state":"running","chapterProgress":[]}"#.utf8))
        store.persist(snapshot: snapshot, chapterIndex: 0, sourceChapterIndex: 3,
            positionSeconds: 10, isPlaying: false, force: false)
        XCTAssertEqual(store.marker(jobId: "throttle", chapterIndex: 0)?.positionSeconds, 10,
                       "The first unforced write is not throttled")
        store.persist(snapshot: snapshot, chapterIndex: 0, sourceChapterIndex: 3,
            positionSeconds: 20, isPlaying: false, force: false)
        XCTAssertEqual(store.marker(jobId: "throttle", chapterIndex: 0)?.positionSeconds, 10,
                       "An unforced write within five seconds is dropped")
        store.persist(snapshot: snapshot, chapterIndex: 0, sourceChapterIndex: 3,
            positionSeconds: 30, isPlaying: true, force: true)
        let marker = try XCTUnwrap(store.marker(jobId: "throttle", chapterIndex: 0))
        XCTAssertEqual(marker.positionSeconds, 15, "A playing state resumes 15 seconds earlier")
        XCTAssertTrue(marker.wasPlaying)
    }
}
