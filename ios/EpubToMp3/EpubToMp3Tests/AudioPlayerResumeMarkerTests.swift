import XCTest
@testable import EpubToMp3

final class AudioPlayerResumeMarkerTests: XCTestCase {
    func testResumeMarkerToPersistBeforeTeardownUsesCurrentSnapshotAndPosition() {
        let marker = PlaybackResumeStore.markerBeforeTeardown(
            jobId: "job-123",
            chapterIndex: 4,
            positionSeconds: 45
        )

        XCTAssertEqual(marker?.jobId, "job-123")
        XCTAssertEqual(marker?.chapterIndex, 4)
        XCTAssertEqual(marker?.positionSeconds, 45)
    }

    func testResumeMarkerToPersistBeforeTeardownSkipsMissingOrTooShortPositions() {
        XCTAssertNil(
            PlaybackResumeStore.markerBeforeTeardown(
                jobId: nil,
                chapterIndex: 4,
                positionSeconds: 45
            )
        )
        XCTAssertNil(
            PlaybackResumeStore.markerBeforeTeardown(
                jobId: "job-123",
                chapterIndex: 4,
                positionSeconds: 1
            )
        )
        XCTAssertNil(
            PlaybackResumeStore.markerBeforeTeardown(
                jobId: "job-123",
                chapterIndex: 4,
                positionSeconds: .nan
            )
        )
    }
}
