import Foundation

/// The actions exposed by the selection floater.
enum ReaderSelectionAction: Equatable {
    case playFromHere
    case playChapterStart
    case sentence
    case paragraph

    static let menuOrder: [ReaderSelectionAction] = [
        .playFromHere, .playChapterStart, .sentence, .paragraph
    ]

    var titleKey: String {
        switch self {
        case .playFromHere: return "reader.selection.playFromHere"
        case .playChapterStart: return "reader.selection.playChapterStart"
        case .sentence: return "reader.selection.playSentence"
        case .paragraph: return "reader.selection.playParagraph"
        }
    }

    var accessibilityIdentifier: String { titleKey }
}

/// Pure interaction state for the reader's automatic audio-follow affordance.
/// Hosts own navigation/audio state and can use this value type without
/// coupling their views to a particular player implementation.
struct ReaderFollowState: Equatable {
    static let cooldownDuration: TimeInterval = 5

    private(set) var following: Bool
    private(set) var cooldownEndsAt: Date?

    init(following: Bool, cooldownEndsAt: Date? = nil) {
        self.following = following
        self.cooldownEndsAt = cooldownEndsAt
    }

    var cooldownDuration: TimeInterval { Self.cooldownDuration }

    mutating func manualNavigation(at date: Date) {
        following = false
        cooldownEndsAt = date.addingTimeInterval(Self.cooldownDuration)
    }

    mutating func followAudio() {
        following = true
        cooldownEndsAt = nil
    }

    func shouldPresentFollowButton(at date: Date) -> Bool {
        guard !following, let cooldownEndsAt else { return false }
        return date < cooldownEndsAt
    }

    /// Hosts can use this to hand control back to audio after the cooldown
    /// expires, while still allowing the user to resume immediately via the
    /// button during the cooldown.
    func shouldFollowAudio(at date: Date) -> Bool {
        guard let cooldownEndsAt else { return following }
        return following || date >= cooldownEndsAt
    }
}

/// Dependency-injected callbacks for a selected sentence and its paragraph.
/// The model is deliberately view-independent so UIKit/TextKit selection hosts
/// can use it alongside SwiftUI without owning SwiftUI gesture state.
struct ReaderSelectionActionFloaterModel {
    let sentence: SentenceSpan?
    let paragraphFirstSentence: SentenceSpan?
    let onPlayFromHere: ((SentenceSpan) -> Void)?
    let onPlayChapterStart: (() -> Void)?
    let onPlaySentence: (SentenceSpan) -> Void
    let onPlayParagraph: (SentenceSpan) -> Void

    init(
        sentence: SentenceSpan?,
        paragraphFirstSentence: SentenceSpan?,
        onPlayFromHere: ((SentenceSpan) -> Void)? = nil,
        onPlayChapterStart: (() -> Void)? = nil,
        onPlaySentence: @escaping (SentenceSpan) -> Void,
        onPlayParagraph: @escaping (SentenceSpan) -> Void
    ) {
        self.sentence = sentence
        self.paragraphFirstSentence = paragraphFirstSentence
        self.onPlayFromHere = onPlayFromHere
        self.onPlayChapterStart = onPlayChapterStart
        self.onPlaySentence = onPlaySentence
        self.onPlayParagraph = onPlayParagraph
    }

    var isPresented: Bool {
        sentence != nil && paragraphFirstSentence != nil
    }

    func perform(_ action: ReaderSelectionAction) {
        switch action {
        case .playFromHere:
            if let sentence { onPlayFromHere?(sentence) }
        case .playChapterStart:
            onPlayChapterStart?()
        case .sentence:
            if let sentence { onPlaySentence(sentence) }
        case .paragraph:
            if let paragraphFirstSentence { onPlayParagraph(paragraphFirstSentence) }
        }
    }
}
