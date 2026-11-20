import Foundation

/// The book that owns a playable snapshot's audio, and how the snapshot's
/// chapter indices map onto the store's zero-based reader axis.
struct RetainedAudioOwner: Equatable, Sendable {
    let bookID: String
    /// The snapshot's declared chapter index base, 0 or 1.
    let indexBase: Int

    func storeIndex(forSnapshotIndex index: Int) -> Int? {
        index >= indexBase ? index - indexBase : nil
    }

    func snapshotIndex(forStoreIndex index: Int) -> Int { index + indexBase }

    /// Nil when the snapshot does not declare its index axis, its job has no
    /// ownership record, or the job's indices are the converter's own rather
    /// than the reader's. Titles and index heuristics never establish identity.
    static func resolve(
        _ snapshot: JobSnapshot, rustOutputs: RustConversionOutputStore = .shared
    ) async -> RetainedAudioOwner? {
        guard let base = snapshot.chapterIndexBase, base == 0 || base == 1 else { return nil }
        let embeddedPrefix = "embedded-"
        if snapshot.jobId.hasPrefix(embeddedPrefix) {
            let bookID = String(snapshot.jobId.dropFirst(embeddedPrefix.count))
            return bookID.isEmpty ? nil : RetainedAudioOwner(bookID: bookID, indexBase: base)
        }
        guard let owner = await rustOutputs.recordedOwner(ofJob: snapshot.jobId), owner.usesReaderAxis else {
            return nil
        }
        return RetainedAudioOwner(bookID: owner.bookID, indexBase: base)
    }
}
