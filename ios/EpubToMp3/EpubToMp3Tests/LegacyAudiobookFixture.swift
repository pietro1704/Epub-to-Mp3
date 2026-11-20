import Foundation
import XCTest
@testable import EpubToMp3

/// Seeds the previous `Audiobooks/<jobId>` layout the way older app versions
/// left it on disk. The app no longer writes that layout; it only reads,
/// migrates and removes it.
enum LegacyAudiobookFixture {
    static func save(_ manifest: AudiobookManifest) throws {
        let url = try XCTUnwrap(AudiobookDownloadStorage.manifestURL(for: manifest.jobId))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: url, options: .atomic)
    }

    /// A Download manager whose kept audio goes to `store`, with each test job
    /// standing for its own book on the zero-based axis.
    static func downloads(store: LocalAudioArtifactStore) -> AudiobookDownloads {
        AudiobookDownloads(store: store,
                           resolveOwner: { RetainedAudioOwner(bookID: $0.jobId, indexBase: 0) },
                           stopLegacyMigration: {})
    }
}
