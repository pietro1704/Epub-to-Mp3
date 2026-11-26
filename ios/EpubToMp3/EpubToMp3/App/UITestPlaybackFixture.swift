import Foundation

#if os(iOS)
@MainActor
enum UITestPlaybackFixture {
    static func installIfRequested(library: LibraryStore, player: AudioPlayer) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-uiTestPlaybackFixture") else { return }
        #if DEBUG
        // The mini player needs a library entry, and an isolated launch starts without one.
        if AppIsolation.isActive, library.books.isEmpty { library.showUITestPlaceholderBook() }
        #endif
        let testReaderLocation = arguments.contains("-uiTestPlaybackReaderLocation")
        let chapterIndex = testReaderLocation ? 1 : 0
        let snapshotIndexBase: Int? = testReaderLocation ? 1 : nil

        if arguments.contains("-uiTestPlaybackLongChapters") {
            installLongChapters(library: library, player: player)
            return
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ui-test-playback.wav")
        try? makeWAV(seconds: 0.5, frequency: 440).write(to: url, options: .atomic)

        let chapter = JobSnapshot.Chapter(
            index: chapterIndex + (snapshotIndexBase ?? 0), name: "UI Test Chapter", status: "completed",
            downloadUrl: url.absoluteString, chars: 100, charsProcessed: 100,
            progressRatio: 1, durationSeconds: 0.5, startedAt: nil, completedAt: nil,
            textOffset: testReaderLocation ? 3_600 : nil
        )
        let fixtureBookID = library.books.first?.id ?? "ui-test-book"
        let snapshot = JobSnapshot(
            jobId: testReaderLocation ? "embedded-\(fixtureBookID)" : "ui-test-playback",
            state: "finished", bookTitle: "UI Test Book",
            bookAuthor: nil, coverUrl: nil, coverMimeType: nil, engine: "fixture",
            voice: nil, language: "en", progressPercent: 100, chaptersTotal: 1,
            chaptersCompleted: 1, chapterProgress: [chapter], outputs: nil,
            logUrl: nil, error: nil, lastActivityAt: nil, chapterIndexBase: snapshotIndexBase
        )
        if testReaderLocation {
            ReaderProgressStore.save(bookId: fixtureBookID, chapterIndex: 0, offsetFraction: 0, characterOffset: 0)
        }
        PlaybackBindingStore.setCurrentlyPlaying(bookID: fixtureBookID, chapterIndex: chapterIndex, defaults: player.location.defaults)
        player.play(snapshot: snapshot, restoreAutoplay: !testReaderLocation)
    }

    /// Two locally generated tone chapters (70 s and 180 s) for the physical-device
    /// background/lock journey. No Piper, model or network is involved. Chapter
    /// names are fixed so UI tests can identify the active chapter.
    private static func installLongChapters(library: LibraryStore, player: AudioPlayer) {
        let specs: [(name: String, seconds: Double, frequency: Double)] = [
            ("BG Lock Chapter 1", 70, 440), ("BG Lock Chapter 2", 180, 660)
        ]
        let directory = FileManager.default.temporaryDirectory
        let chapters: [JobSnapshot.Chapter] = specs.enumerated().compactMap { index, spec in
            let url = directory.appendingPathComponent("ui-test-bg-lock-\(index + 1).wav")
            do { try makeWAV(seconds: spec.seconds, frequency: spec.frequency).write(to: url, options: .atomic) } catch {
                return nil
            }
            return JobSnapshot.Chapter(
                index: index, name: spec.name, status: "completed",
                downloadUrl: url.absoluteString, chars: 100, charsProcessed: 100,
                progressRatio: 1, durationSeconds: spec.seconds, startedAt: nil, completedAt: nil,
                textOffset: nil
            )
        }
        guard chapters.count == specs.count else { return }
        let fixtureBookID = library.books.first?.id ?? "ui-test-book"
        let snapshot = JobSnapshot(
            jobId: "ui-test-bg-lock-playback",
            state: "finished", bookTitle: "UI Test Book",
            bookAuthor: nil, coverUrl: nil, coverMimeType: nil, engine: "fixture",
            voice: nil, language: "en", progressPercent: 100, chaptersTotal: chapters.count,
            chaptersCompleted: chapters.count, chapterProgress: chapters, outputs: nil,
            logUrl: nil, error: nil, lastActivityAt: nil, chapterIndexBase: nil
        )
        PlaybackBindingStore.setCurrentlyPlaying(bookID: fixtureBookID, chapterIndex: 0)
        // Starts playing like the short fixture: on the 16e a paused fixture
        // queue did not start from the full player's Play control.
        player.play(snapshot: snapshot, restoreAutoplay: true)
    }

    private static func makeWAV(seconds: Double, frequency: Double) -> Data {
        let sampleRate: UInt32 = 8_000
        let sampleCount = Int(Double(sampleRate) * seconds)
        var pcm = Data(capacity: sampleCount * 2)
        for index in 0..<sampleCount {
            let phase = Double(index) / Double(sampleRate) * 2 * .pi * frequency
            var sample = Int16(sin(phase) * 2_000).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        appendLittleEndian(UInt32(36 + pcm.count), to: &wav)
        wav.append(contentsOf: Array("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav)
        appendLittleEndian(sampleRate, to: &wav)
        appendLittleEndian(sampleRate * 2, to: &wav)
        appendLittleEndian(UInt16(2), to: &wav)
        appendLittleEndian(UInt16(16), to: &wav)
        wav.append(contentsOf: Array("data".utf8))
        appendLittleEndian(UInt32(pcm.count), to: &wav)
        wav.append(pcm)
        return wav
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}
#endif
