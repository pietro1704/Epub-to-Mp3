#if canImport(AVFoundation) && canImport(MediaPlayer)
import XCTest
import AVFoundation
@testable import EpubToMp3

/// Tests for the segment-streaming additions to `AudioPlayer`:
/// `enqueueSegment(data:chapterIndex:segmentIndex:)`, `firstSegmentReady`,
/// and the interaction with `firstChapterReady` / `clearConversionState()`.
///
/// No real audio session or Edge-TTS calls are made — we feed synthetic
/// MP3 stubs and verify state transitions. Runs on the macOS host.
final class AudioPlayerStreamingTests: XCTestCase {

    // MARK: - Helpers

    /// Returns the smallest valid MPEG Layer-III frame header (4 bytes)
    /// followed by padding so AVFoundation is happy probing the file.
    /// This is not a real MP3 but is sufficient for `AVPlayerItem` to
    /// accept the URL without crashing during probe; actual audio would
    /// require a real encoded frame.
    func fakeMP3(size: Int = 512) -> Data {
        // MPEG1, Layer3, 128 kbps, 44100 Hz, stereo header bytes.
        var d = Data([0xFF, 0xFB, 0x90, 0x00])
        d.append(contentsOf: [UInt8](repeating: 0x00, count: max(0, size - 4)))
        return d
    }

    // MARK: - firstSegmentReady




    // MARK: - No-autoplay guarantee






    // MARK: - firstChapterReady co-advancement


    // MARK: - isLoading respects firstSegmentReady


    // MARK: - Empty data ignored


    // MARK: - Multiple segments enqueued






    // MARK: - clearConversionState resets firstSegmentReady


    // MARK: - Streaming then whole-chapter play interop


    // MARK: - SSE snapshot streaming




    // MARK: - AsyncStream multi-consumer (TSan-compatible)



    func chapter(index: Int, url: String?) -> JobSnapshot.Chapter {
        JobSnapshot.Chapter(
            index: index,
            name: "Chapter \(index + 1)",
            status: url == nil ? "converting" : "completed",
            downloadUrl: url,
            chars: 100,
            charsProcessed: url == nil ? 10 : 100,
            progressRatio: url == nil ? 0.1 : 1.0,
            durationSeconds: nil,
            startedAt: nil,
            completedAt: nil
        )
    }

    func snapshot(chapters: [JobSnapshot.Chapter], state: String) -> JobSnapshot {
        JobSnapshot(
            jobId: "streaming-snapshot-job",
            state: state,
            bookTitle: "Streaming Book",
            bookAuthor: nil,
            coverUrl: nil,
            coverMimeType: nil,
            engine: nil,
            voice: nil,
            language: nil,
            progressPercent: nil,
            chaptersTotal: chapters.count,
            chaptersCompleted: chapters.filter { $0.downloadUrl != nil }.count,
            chapterProgress: chapters,
            outputs: nil,
            logUrl: nil,
            error: nil,
            lastActivityAt: nil
        )
    }
}

// MARK: - JobSnapshot test stubs

extension JobSnapshot {
    static func stub(playableCount: Int) -> JobSnapshot {
        let chapters = (0..<playableCount).map { i in
            JobSnapshot.Chapter(
                index: i,
                name: "Chapter \(i + 1)",
                status: "completed",
                downloadUrl: "/fake/ch\(i).mp3",
                chars: nil,
                charsProcessed: nil,
                progressRatio: 1.0,
                durationSeconds: nil,
                startedAt: nil,
                completedAt: nil
            )
        }
        return JobSnapshot(
            jobId: "stub-\(UUID().uuidString)",
            state: "completed",
            bookTitle: "Stub Book",
            bookAuthor: nil,
            coverUrl: nil,
            coverMimeType: nil,
            engine: nil,
            voice: nil,
            language: nil,
            progressPercent: nil,
            chaptersTotal: playableCount,
            chaptersCompleted: playableCount,
            chapterProgress: chapters.isEmpty ? nil : chapters,
            outputs: nil,
            logUrl: nil,
            error: nil,
            lastActivityAt: nil
        )
    }
}
#endif
