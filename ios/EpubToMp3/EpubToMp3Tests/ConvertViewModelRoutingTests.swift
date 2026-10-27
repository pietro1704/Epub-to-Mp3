import XCTest
@testable import EpubToMp3

@MainActor
final class ConvertViewModelRoutingTests: XCTestCase {
    func testLegacyRemoteFlagStillRoutesTheExactFileAndRangeThroughEmbeddedExecutor() async {
        let input = URL(fileURLWithPath: "/fixture-only/Book with spaces.epub")
        var captured: (URL, Int32, Int32)?
        let model = ConvertViewModel(converter: { file, start, end, _ in
            captured = (file, start, end)
            return .init(jobID: "embedded-route", manifestJSON: Data(), outputDirectory: input.deletingLastPathComponent())
        })
        model.selectedFile = input
        model.chapters = "8-9"
        await model.submit(client: nil, useEmbeddedRuntime: false)
        XCTAssertEqual(captured?.0, input)
        XCTAssertEqual(captured?.1, 8)
        XCTAssertEqual(captured?.2, 9)
        XCTAssertEqual(model.submittedJobId, "embedded-route")
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isSubmitting)
    }

    func testMissingInputAndInvalidRangeNeverReachExecutor() async {
        var calls = 0
        let model = ConvertViewModel(converter: { _, _, _, _ in calls += 1; throw CancellationError() })
        await model.submit()
        XCTAssertEqual(model.error, L10n.string("convert.error.pickFileFirst"))
        model.selectedFile = URL(fileURLWithPath: "/fixture-only/input.epub")
        model.chapters = "invalid-range"
        await model.submit()
        XCTAssertNotNil(model.error)
        XCTAssertEqual(calls, 0)
        XCTAssertNil(model.submittedJobId)
        XCTAssertFalse(model.isSubmitting)
    }

    func testCancelledEmbeddedExecutorClearsSubmissionWithoutPublishingAJob() async {
        let model = ConvertViewModel(converter: { _, _, _, _ in throw CancellationError() })
        model.selectedFile = URL(fileURLWithPath: "/fixture-only/input.epub")
        await model.submit(useEmbeddedRuntime: true)
        XCTAssertNil(model.submittedJobId)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.session.phase, .cancelled)
        XCTAssertFalse(model.isSubmitting)
    }
}
