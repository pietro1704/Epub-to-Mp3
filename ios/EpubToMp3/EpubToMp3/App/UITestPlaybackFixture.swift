import Foundation

#if os(iOS)
@MainActor
enum UITestPlaybackFixture {
    static func installIfRequested(library: LibraryStore, player: AudioPlayer) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-uiTestPlaybackFixture") else { return }
        let testReaderLocation = arguments.contains("-uiTestPlaybackReaderLocation")
        let chapterIndex = testReaderLocation ? 1 : 0
        let snapshotIndexBase: Int? = testReaderLocation ? 1 : nil

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ui-test-playback.wav")
        let sampleRate: UInt32 = 8_000
        let sampleCount = Int(sampleRate / 2)
        var pcm = Data(capacity: sampleCount * 2)
        for index in 0..<sampleCount {
            let phase = Double(index) / Double(sampleRate) * 2 * .pi * 440
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
        try? wav.write(to: url, options: .atomic)

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
        PlaybackBindingStore.setCurrentlyPlaying(bookID: fixtureBookID, chapterIndex: chapterIndex)
        player.play(snapshot: snapshot, restoreAutoplay: !testReaderLocation)
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}
#endif
