import Foundation

/// Value-type location shared by the reader and audio surfaces.
struct ReaderAudioPositionAnchor: Equatable, Hashable, Sendable {
    let chapterIndex: Int
    let sentenceID: String?
    let pageRatio: Double?
    let scrollOffset: Double?

    var isMeaningful: Bool {
        chapterIndex >= 0 && (sentenceID != nil || pageRatio != nil || scrollOffset != nil)
    }
}

struct ManualDivergenceStateMachine: Equatable, Sendable {
    let cooldown: TimeInterval
    private(set) var divergenceDeadline: Date?

    init(cooldown: TimeInterval = 5) {
        self.cooldown = max(0, cooldown)
    }

    mutating func manualMove(at date: Date) {
        divergenceDeadline = date.addingTimeInterval(cooldown)
    }

    func isDivergent(at date: Date) -> Bool {
        guard let deadline = divergenceDeadline else { return false }
        return date < deadline
    }

    func shouldFollowAudio(at date: Date) -> Bool {
        !isDivergent(at: date)
    }

    mutating func followAudio() {
        divergenceDeadline = nil
    }

    mutating func reset() {
        divergenceDeadline = nil
    }
}
