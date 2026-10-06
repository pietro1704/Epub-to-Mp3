import XCTest
@testable import EpubToMp3

final class StreamingDiagnosticsSessionTests: XCTestCase {
    func testDefaultAndNewProcessSessionDoNotAuthorizeRequests() {
        let session = StreamingDiagnosticsSession()
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.authorization(for: UUID()))
        session.activate()
        XCTAssertNotNil(session.authorization(for: UUID()))
        let relaunched = StreamingDiagnosticsSession()
        XCTAssertFalse(relaunched.isActive)
        XCTAssertNil(relaunched.authorization(for: UUID()))
    }

    func testExplicitActivationExpiresAtFiveMinutesWithoutRenewingOnReads() throws {
        var now: UInt64 = 1_000
        let session = StreamingDiagnosticsSession(clock: { now })
        session.activate()
        let journey = UUID()
        let authorization = try XCTUnwrap(session.authorization(for: journey))
        XCTAssertEqual(authorization.journeyID, journey)
        XCTAssertTrue(authorization.isValid)
        XCTAssertEqual(session.remainingTime, 300)
        now += 299_000_000_000
        for _ in 0..<10 {
            XCTAssertEqual(session.remainingTime, 1)
            XCTAssertTrue(authorization.isValid)
        }
        now += 1_000_000_000
        XCTAssertFalse(session.isActive)
        XCTAssertFalse(authorization.isValid)
        XCTAssertNil(session.authorization(for: journey))
    }

    func testStopAndNewActivationNeverReviveAnOldRequestAuthorization() throws {
        let session = StreamingDiagnosticsSession(clock: { 0 })
        let firstID = session.activate()
        let first = try XCTUnwrap(session.authorization(for: UUID()))
        session.deactivate()
        XCTAssertFalse(first.isValid)
        let secondID = session.activate()
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertFalse(first.isValid)
        let second = try XCTUnwrap(session.authorization(for: UUID()))
        XCTAssertTrue(second.isValid)
        session.activate()
        XCTAssertFalse(second.isValid)
    }

    func testExpiredConsentDoesNotReturnWhenClockMovesBackwards() throws {
        var now: UInt64 = 1_000
        let session = StreamingDiagnosticsSession(clock: { now })
        session.activate()
        let authorization = try XCTUnwrap(session.authorization(for: UUID()))
        now += 300_000_000_000
        XCTAssertFalse(authorization.isValid)
        now = 1_000
        XCTAssertFalse(authorization.isValid)
        XCTAssertFalse(session.isActive)
    }

    func testClockOverflowCannotExtendConsent() throws {
        var now = UInt64.max - 10
        let session = StreamingDiagnosticsSession(clock: { now })
        session.activate()
        let authorization = try XCTUnwrap(session.authorization(for: UUID()))
        now = 0
        XCTAssertFalse(authorization.isValid)
        XCTAssertEqual(session.remainingTime, 0)
    }
}
