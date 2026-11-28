import XCTest
@testable import EpubToMp3

/// REMOTE-JUMP-LOSES-FOLLOW (related path): playback resumed with no reader open (mini player or remote
/// command in the library after a relaunch) must still belong to the narrated book. The reader follows and
/// highlights the narration only for that book.
@MainActor
final class PlaybackAnchorWithoutReaderTests: XCTestCase {
    func testResumingWithNoReaderOpenKeepsTheNarratedBookForItsReader() throws {
        let suite = "playback-anchor-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let location = ReaderLocation(defaults: defaults)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)),
                                 location: location)
        defer {
            player.stop()
            defaults.removePersistentDomain(forName: suite)
        }
        // State left by a closed reader: the playing book and the last reader chapter survive, no book is open.
        location.bindPlayingBook("narrated", chapter: 1)
        location.readerChapter = 1
        location.setReadingBook(nil)

        player.resume()
        location.setReadingBook("narrated")

        XCTAssertTrue(player.isPlaybackForReaderBook("narrated"), "its reader must follow the narration")
        XCTAssertFalse(player.isPlaybackForReaderBook("another"))
    }
}
