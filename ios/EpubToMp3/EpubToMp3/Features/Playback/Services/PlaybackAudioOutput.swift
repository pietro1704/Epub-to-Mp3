import Combine
import Foundation

/// Confirmed advancing media time, scoped to the current item. Intent to play
/// never creates a sample. A watchdog clears stale output even if ticks stop.
@MainActor
final class PlaybackAudioOutput: ObservableObject {
    struct Position: Equatable {
        let chapterIndex: Int
        let seconds: TimeInterval
        let duration: TimeInterval
        let sentenceID: String?
        let itemSeconds: TimeInterval
        let itemDuration: TimeInterval
    }
    @Published private(set) var position: Position?
    private var previous: (item: ObjectIdentifier, seconds: TimeInterval)?
    private var expiry: Task<Void, Never>?

    func sample(item: ObjectIdentifier?, seconds: TimeInterval, isOutputting: Bool, position: Position) {
        guard let item, seconds.isFinite, isOutputting else { clear(); return }
        let advanced = previous.map { $0.item == item && seconds > $0.seconds } ?? false
        previous = (item, seconds)
        guard advanced else { expire(); return }
        self.position = position
        expiry?.cancel()
        expiry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 800_000_000) } catch { return }
            self?.clear()
        }
    }

    func clear() {
        previous = nil
        expire()
    }

    private func expire() {
        expiry?.cancel()
        expiry = nil
        if position != nil { position = nil }
    }
}
