import XCTest
@testable import EpubToMp3

final class ReaderInteractionComponentsTests: XCTestCase {
    func testSelectionActionLabelsAndAccessibilityIdentifiersAreStable() {
        XCTAssertEqual(ReaderSelectionAction.sentence.titleKey, "reader.selection.playSentence")
        XCTAssertEqual(ReaderSelectionAction.paragraph.titleKey, "reader.selection.playParagraph")
        XCTAssertEqual(ReaderSelectionAction.sentence.accessibilityIdentifier, "reader.selection.playSentence")
        XCTAssertEqual(ReaderSelectionAction.paragraph.accessibilityIdentifier, "reader.selection.playParagraph")
        XCTAssertEqual(ReaderFollowButton.accessibilityIdentifier, "reader.followButton")
        XCTAssertEqual(ReaderFollowButton.titleKey, "reader.follow")
    }

    func testSelectionActionFloaterRoutesSentenceAndParagraphCallbacks() {
        let sentence = SentenceSpan(id: "2:4", text: "A sentence.", startChar: 0, endChar: 11)
        let paragraph = SentenceSpan(id: "2:0", text: "First sentence.", startChar: 0, endChar: 15)
        var received: [ReaderSelectionAction] = []
        var receivedSpans: [SentenceSpan] = []
        let model = ReaderSelectionActionFloaterModel(
            sentence: sentence,
            paragraphFirstSentence: paragraph,
            onPlaySentence: { received.append(.sentence); receivedSpans.append($0) },
            onPlayParagraph: { received.append(.paragraph); receivedSpans.append($0) }
        )

        model.perform(.sentence)
        model.perform(.paragraph)

        XCTAssertEqual(received, [.sentence, .paragraph])
        XCTAssertEqual(receivedSpans, [sentence, paragraph])
    }

    func testSelectionActionFloaterRequiresBothTargetsToBePresented() {
        let sentence = SentenceSpan(id: "1:0", text: "Sentence.", startChar: 0, endChar: 9)
        let model = ReaderSelectionActionFloaterModel(
            sentence: sentence,
            paragraphFirstSentence: nil,
            onPlaySentence: { _ in },
            onPlayParagraph: { _ in }
        )

        XCTAssertFalse(model.isPresented)
    }

    func testManualNavigationPausesFollowingAndShowsButtonForFiveSeconds() {
        let now = Date(timeIntervalSince1970: 1_000)
        var state = ReaderFollowState(following: true)

        state.manualNavigation(at: now)

        XCTAssertFalse(state.following)
        XCTAssertEqual(state.cooldownDuration, 5)
        XCTAssertTrue(state.shouldPresentFollowButton(at: now))
        XCTAssertTrue(state.shouldPresentFollowButton(at: now.addingTimeInterval(4.999)))
        XCTAssertFalse(state.shouldPresentFollowButton(at: now.addingTimeInterval(5)))
        XCTAssertTrue(state.shouldFollowAudio(at: now.addingTimeInterval(5)))
    }

    func testFollowActionImmediatelyResumesAndHidesButton() {
        let now = Date(timeIntervalSince1970: 1_000)
        var state = ReaderFollowState(following: false)
        state.manualNavigation(at: now)
        state.followAudio()

        XCTAssertTrue(state.following)
        XCTAssertFalse(state.shouldPresentFollowButton(at: now))
    }
}
