import XCTest
@testable import EpubToMp3

final class AudioPlayerResumeMarkerTests: XCTestCase {
    func testResumeMarkerToPersistBeforeTeardownUsesCurrentSnapshotAndPosition() {
        let marker = AudioPlayer.resumeMarkerToPersistBeforeTeardown(
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
            AudioPlayer.resumeMarkerToPersistBeforeTeardown(
                jobId: nil,
                chapterIndex: 4,
                positionSeconds: 45
            )
        )
        XCTAssertNil(
            AudioPlayer.resumeMarkerToPersistBeforeTeardown(
                jobId: "job-123",
                chapterIndex: 4,
                positionSeconds: 1
            )
        )
        XCTAssertNil(
            AudioPlayer.resumeMarkerToPersistBeforeTeardown(
                jobId: "job-123",
                chapterIndex: 4,
                positionSeconds: .nan
            )
        )
    }
}
