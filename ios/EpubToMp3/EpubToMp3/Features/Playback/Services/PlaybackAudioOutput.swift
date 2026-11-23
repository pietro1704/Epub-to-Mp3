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
        var alignment: SpeechAudioAlignment? = nil
        var bookID: String? = nil
    }
    @Published private(set) var position: Position?
    private var previous: (item: ObjectIdentifier, seconds: TimeInterval)?
    private var expiry: Task<Void, Never>?

    private var readerJob: (jobID: String, bookID: String)?
    private var mountedJobID: String?

    func bindReaderJob(_ jobID: String, to bookID: String) {
        readerJob = (jobID, bookID)
    }

    func didMountQueue(for jobID: String?) {
        clear()
        mountedJobID = jobID
    }

    func snapshotChanged(to jobID: String?) {
        // A different projection can reuse the live queue. Until the queue is
        // mounted again its items cannot safely be attributed to the new job.
        if mountedJobID != jobID {
            mountedJobID = nil
            clear()
        }
    }

    func bookID(for jobID: String?) -> String? {
        guard let jobID else { return nil }
        let prefix = "embedded-"
        if jobID.hasPrefix(prefix) {
            let id = jobID.dropFirst(prefix.count)
            return id.isEmpty ? nil : String(id)
        }
        return readerJob?.jobID == jobID ? readerJob?.bookID : nil
    }

    func sample(item: ObjectIdentifier?, seconds: TimeInterval, isOutputting: Bool, position: Position) {
        guard let item, seconds.isFinite, isOutputting else { clear(); return }
        let advanced = previous.map { $0.item == item && seconds > $0.seconds } ?? false
        previous = (item, seconds)
        guard advanced else { expire(); return }
        var confirmed = position
        confirmed.bookID = bookID(for: mountedJobID)
        self.position = confirmed
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
