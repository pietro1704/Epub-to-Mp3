import Combine
import XCTest
@testable import EpubToMp3

/// READER-FOLLOW-NARRATION: the reader follows the narration until the user turns a page by hand.
final class ReaderFollowNarrationTests: XCTestCase {
    func testFollowsOnlyWhileNarratingAndOffThePage() {
        var follow = ReaderFollowNarration()
        XCTAssertTrue(follow.shouldFollow(paired: false, isNarrating: true), "The spoken passage left the screen")
        XCTAssertFalse(follow.shouldFollow(paired: true, isNarrating: true), "Nothing to do while the page holds the passage")
        XCTAssertFalse(follow.shouldFollow(paired: false, isNarrating: false), "Paused or other book: never moves the reader")
    }

    func testAManualPageTurnStopsFollowing() {
        var follow = ReaderFollowNarration()
        follow.apply(.manualPageTurn)
        XCTAssertTrue(follow.isSuspended)
        XCTAssertFalse(follow.shouldFollow(paired: false, isNarrating: true))
        XCTAssertFalse(follow.shouldFollow(paired: false, isNarrating: true), "Stays suspended on every later tick")
    }

    func testFollowingResumesWhenThePageHoldsTheSpokenPassageAgain() {
        var follow = ReaderFollowNarration()
        follow.apply(.manualPageTurn)
        XCTAssertFalse(follow.shouldFollow(paired: true, isNarrating: true), "Reaching the passage does not move the reader")
        XCTAssertFalse(follow.isSuspended)
        XCTAssertTrue(follow.shouldFollow(paired: false, isNarrating: true), "The next time it leaves the page, follow")
    }

    func testPairingWhilePausedAlsoClearsTheSuspension() {
        var follow = ReaderFollowNarration()
        follow.apply(.manualPageTurn)
        _ = follow.shouldFollow(paired: true, isNarrating: false)
        XCTAssertFalse(follow.isSuspended)
    }

    func testGoToReadingAndExplicitNarrationJumpsResumeFollowing() {
        for event in [ReaderFollowNarration.Event.goToReading, .explicitNarrationJump] {
            var follow = ReaderFollowNarration()
            follow.apply(.manualPageTurn)
            follow.apply(event)
            XCTAssertFalse(follow.isSuspended, "\(event)")
            XCTAssertTrue(follow.shouldFollow(paired: false, isNarrating: true), "\(event)")
        }
    }

    func testTextDirectionForwardAndBackwardAcrossPagesAndChapters() {
        let page = NSRange(location: 1_000, length: 800)
        typealias F = ReaderFollowNarration
        XCTAssertEqual(F.direction(spokenChapter: 2, spokenOffset: 1_800, readerChapter: 2, visible: page), .forward)
        XCTAssertEqual(F.direction(spokenChapter: 2, spokenOffset: 999, readerChapter: 2, visible: page), .backward,
                       "Seeking back moves the reader backward")
        XCTAssertNil(F.direction(spokenChapter: 2, spokenOffset: 1_000, readerChapter: 2, visible: page))
        XCTAssertNil(F.direction(spokenChapter: 2, spokenOffset: 1_799, readerChapter: 2, visible: page))
        XCTAssertEqual(F.direction(spokenChapter: 3, spokenOffset: 0, readerChapter: 2, visible: page), .forward,
                       "A later chapter is forward whatever the offsets")
        XCTAssertEqual(F.direction(spokenChapter: 1, spokenOffset: 5_000, readerChapter: 2, visible: page), .backward)
    }

    func testTextDirectionIsNilWhenAnythingIsUnknown() {
        let page = NSRange(location: 0, length: 100)
        typealias F = ReaderFollowNarration
        XCTAssertNil(F.direction(spokenChapter: nil, spokenOffset: 5, readerChapter: 0, visible: page))
        XCTAssertNil(F.direction(spokenChapter: 0, spokenOffset: nil, readerChapter: 0, visible: page))
        XCTAssertNil(F.direction(spokenChapter: 0, spokenOffset: 5, readerChapter: nil, visible: page))
        XCTAssertNil(F.direction(spokenChapter: 0, spokenOffset: 5, readerChapter: 0, visible: nil))
        XCTAssertNil(F.direction(spokenChapter: 0, spokenOffset: 5, readerChapter: 0, visible: NSRange(location: NSNotFound, length: 0)))
    }

    func testPDFDirectionForwardAndBackward() {
        typealias F = ReaderFollowNarration
        XCTAssertEqual(F.direction(spokenPage: 9, visiblePages: [4, 5]), .forward)
        XCTAssertEqual(F.direction(spokenPage: 2, visiblePages: [4, 5]), .backward)
        XCTAssertNil(F.direction(spokenPage: 5, visiblePages: [4, 5]))
        XCTAssertNil(F.direction(spokenPage: nil, visiblePages: [4, 5]))
        XCTAssertNil(F.direction(spokenPage: 5, visiblePages: []))
    }

    @MainActor
    func testEveryUserTransportCommandAnnouncesAnExplicitNarrationJump() throws {
        let suite = "follow-jumps-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        var jumps = 0
        let subscription = player.narrationJumps.sink { jumps += 1 }
        defer { subscription.cancel() }
        player.seek(to: 12)
        player.skip(by: 15)
        player.skipForward()
        player.skipBackward()
        player.nextChapter()
        player.previousChapter()
        XCTAssertEqual(jumps, 6, "Seek, skip (both forms) and chapter changes each resume following")
    }
}

/// The follower is the seam every reader (text, PDF) uses: it must reveal, suspend and resume exactly as the rules say.
@MainActor
final class ReaderNarrationFollowerTests: XCTestCase {
    private let jumps = PassthroughSubject<Void, Never>()
    private var narrating = true
    private var reveals = 0
    private var follower: ReaderNarrationFollower!

    override func setUp() {
        narrating = true
        reveals = 0
        follower = ReaderNarrationFollower(jumps: jumps.eraseToAnyPublisher(), isNarrating: { [unowned self] in narrating },
                                           follow: { [unowned self] in reveals += 1 })
        follower.start(onJump: {})
    }

    func testRevealsWhenTheNarrationLeavesThePageAndNotWhilePairedOrPaused() {
        follower.evaluate(paired: true)
        XCTAssertEqual(reveals, 0)
        narrating = false
        follower.evaluate(paired: false)
        XCTAssertEqual(reveals, 0, "Paused narration never moves the reader")
        narrating = true
        follower.evaluate(paired: false)
        XCTAssertEqual(reveals, 1)
    }

    func testManualTurnSuspendsUntilPairedAgainOrAnExplicitJump() {
        follower.userTurnedThePage()
        follower.evaluate(paired: false)
        XCTAssertEqual(reveals, 0)
        jumps.send()
        follower.evaluate(paired: false)
        XCTAssertEqual(reveals, 1, "Seek, skip or chapter change resumes following")
        follower.userTurnedThePage()
        follower.evaluate(paired: true)
        follower.evaluate(paired: false)
        XCTAssertEqual(reveals, 2, "Reaching the narrated page again resumes following")
        follower.userTurnedThePage()
        follower.userAskedToGoToReading()
        follower.evaluate(paired: false)
        XCTAssertEqual(reveals, 3, "Go to reading resumes following")
    }

    func testTheReadersOwnMoveIsNotAManualTurn() {
        var inner: ReaderNarrationFollower!
        inner = ReaderNarrationFollower(jumps: jumps.eraseToAnyPublisher(), isNarrating: { true },
                                        follow: { inner.userTurnedThePage() })
        inner.evaluate(paired: false)
        XCTAssertFalse(inner.isSuspended, "Page changes caused by following must not suspend following")
        inner.userTurnedThePage()
        XCTAssertTrue(inner.isSuspended)
    }

    func testStoppingDropsTheJumpSubscription() {
        follower.userTurnedThePage()
        follower.stop()
        jumps.send()
        XCTAssertTrue(follower.isSuspended)
    }
}
