#if canImport(AVFoundation) && canImport(MediaPlayer)
import AVFoundation
import Foundation
import CryptoKit
import Darwin
import XCTest
@testable import EpubToMp3

// Shared only by the two existing native observation test suites. Inputs are
// explicit local artifacts, not conversion jobs or whole-book manifests.
struct NativePlaybackBenchmarkInput: Codable, Sendable {
    struct Chapter: Codable, Sendable {
        let sourceIndex: Int
        let path: String
        var sha256: String
    }
    struct Book: Codable, Sendable {
        let name: String
        let sourcePath: String
        let sourceSHA256: String
        var chapterStart: Int
        var chapterEnd: Int
        var chapters: [Chapter]
    }
    let schemaVersion: Int
    let phase: String
    let baselineExecutablePath: String?
    var books: [Book]

    static let environmentKey = "EPUB2MP3_NATIVE_PLAYBACK_BENCHMARK_SPEC"

    static func optIn() throws -> Self {
        guard let json = ProcessInfo.processInfo.environment[environmentKey] else {
            throw XCTSkip("Provide \(environmentKey) with explicit local EPUB/MP3 paths and SHA-256 hashes.")
        }
        let input = try JSONDecoder().decode(Self.self, from: Data(json.utf8))
        try input.validateScope()
        try input.validateRequestedBooks()
        try input.validateFiles()
        return input
    }

    func validateRequestedBooks() throws {
        let expected = [
            "lotr": "3e1c676b270dfa3fe555eba4d0cb993486e9f00facb7cc92eef250e64efb7c9e",
            "christie": "55417053355de78768a0823d3cd203fde5c80bd8026407ffb5766b3f730d11da",
        ]
        for book in books {
            guard expected[book.name] == book.sourceSHA256.lowercased() else {
                throw Self.invalid("Benchmark requires the literal requested EPUB, not a renamed fixture")
            }
        }
    }

    func validateFiles() throws {
        for book in books {
            guard try Self.hash(book.sourcePath) == book.sourceSHA256.lowercased() else {
                throw Self.invalid("EPUB hash mismatch for \(book.name)")
            }
            for chapter in book.chapters {
                guard try Self.hash(chapter.path) == chapter.sha256.lowercased() else {
                    throw Self.invalid("MP3 hash mismatch at source index \(chapter.sourceIndex)")
                }
            }
        }
    }

    func validateScope() throws {
        guard schemaVersion == 1, ["baseline", "candidate"].contains(phase), books.count == 2,
              Set(books.map(\.name)) == Set(["lotr", "christie"]),
              Set(books.map { $0.sourceSHA256.lowercased() }).count == 2 else { throw Self.invalid("Invalid benchmark scope") }
        var paths = Set<String>()
        for book in books {
            let range = book.name == "lotr" ? 8...9 : 6...7
            guard book.chapterStart == range.lowerBound, book.chapterEnd == range.upperBound,
                  book.chapters.count == 2, book.chapters.map(\.sourceIndex) == Array(range) else {
                throw Self.invalid("Select only LOTR 8-9 and Christie 6-7 in source order")
            }
            for (path, digest, ext) in [(book.sourcePath, book.sourceSHA256, "epub")]
                + book.chapters.map({ ($0.path, $0.sha256, "mp3") }) {
                guard (path as NSString).isAbsolutePath, URL(fileURLWithPath: path).pathExtension.lowercased() == ext,
                      paths.insert(path).inserted, digest.count == 64,
                      digest.allSatisfy({ $0.isHexDigit }) else { throw Self.invalid("Invalid local path or SHA-256") }
            }
        }
    }

    static func hash(_ path: String) throws -> String {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        var digest = SHA256()
        while let data = try file.read(upToCount: 65_536), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func invalid(_ message: String) -> NSError {
        NSError(domain: "NativePlaybackBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

struct NativePlaybackBenchmarkReport: Encodable {
    struct Point: Encodable {
        let book: String
        let event: String
        let elapsedNanoseconds: UInt64
        let residentBytes: UInt64?
        let physicalFootprintBytes: UInt64?
        let memoryStatus: Int32
        let journeys: [LatencyObservation.Journey]

        static func capture(book: String, event: String, started: UInt64,
                            journeys: [LatencyObservation.Journey] = []) -> Self {
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return Self(book: book, event: event, elapsedNanoseconds: elapsed,
                        residentBytes: status == KERN_SUCCESS ? info.resident_size : nil,
                        physicalFootprintBytes: status == KERN_SUCCESS ? info.phys_footprint : nil,
                        memoryStatus: status, journeys: journeys)
        }
    }
    let input: NativePlaybackBenchmarkInput
    let executablePath: String
    let executableSHA256: String
    let appCodeSHA256: String
    let baselineStatus: String
    let comparison = "unmeasured: requires paired reports from the actual baseline and candidate executables"
    let clock = "client monotonic; audio progress is not acoustic; memory is point sampled, not peak; cold means prepared-reader cache absent, not OS cache flushed"
    var status = "partial"
    var points: [Point] = []

    init(input: NativePlaybackBenchmarkInput) throws {
        self.input = input
        let executable = try XCTUnwrap(Bundle.main.executableURL).resolvingSymlinksInPath()
        executablePath = executable.path
        executableSHA256 = try NativePlaybackBenchmarkInput.hash(executable.path)
        // Modern Debug builds use an identical launcher across revisions.
        // Identify the loaded app code, not just that launcher stub.
        let debugPayload = executable.deletingLastPathComponent()
            .appendingPathComponent(executable.lastPathComponent + ".debug.dylib")
        appCodeSHA256 = try NativePlaybackBenchmarkInput.hash(
            FileManager.default.isReadableFile(atPath: debugPayload.path) ? debugPayload.path : executable.path)
        if let baseline = input.baselineExecutablePath, FileManager.default.isExecutableFile(atPath: baseline) {
            let sameExecutable = URL(fileURLWithPath: baseline).resolvingSymlinksInPath() == executable
            baselineStatus = sameExecutable
                ? (input.phase == "baseline" ? "this_run_is_baseline" : "unmeasured: baseline path is the current candidate")
                : "available_not_executed"
            if input.phase == "baseline", !sameExecutable {
                throw NativePlaybackBenchmarkInput.invalid("Run the supplied baseline executable; do not label the candidate as baseline")
            }
        } else {
            baselineStatus = "unmeasured: baseline executable unavailable"
            if input.phase == "baseline" { throw NativePlaybackBenchmarkInput.invalid("Baseline executable is required") }
        }
    }

    func attachment(_ name: String) throws -> XCTAttachment {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let attachment = XCTAttachment(data: try encoder.encode(self), uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}

#if os(iOS)
private final class AudioSessionEventTrace: @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchTime.now().uptimeNanoseconds
    private var events: [String] = []

    func append(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        events.append("\((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)ms:\(event)")
        if events.count > 20 { events.removeFirst() }
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return events.joined(separator: ",")
    }
}
#endif

private final class ObservationPrivacyProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var interceptedHost = ""
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func configure(host: String) {
        lock.lock()
        defer { lock.unlock() }
        interceptedHost = host
        requests = []
    }

    static func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return request.url?.host == interceptedHost
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        Self.lock.unlock()
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AudioPlayerObservationPrivacyTests: XCTestCase {
    func testBenchmarkInputScopeAndHashesWithoutMeasuringPerformance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let books = try ["lotr", "christie"].map { name -> NativePlaybackBenchmarkInput.Book in
            let source = root.appendingPathComponent("\(name).epub")
            try Data(name.utf8).write(to: source)
            let range = name == "lotr" ? 8...9 : 6...7
            let chapters = try range.map { index -> NativePlaybackBenchmarkInput.Chapter in
                let path = root.appendingPathComponent("\(name)-\(index).mp3")
                try Data("\(name)-\(index)".utf8).write(to: path)
                return .init(sourceIndex: index, path: path.path, sha256: try NativePlaybackBenchmarkInput.hash(path.path))
            }
            return .init(name: name, sourcePath: source.path, sourceSHA256: try NativePlaybackBenchmarkInput.hash(source.path),
                         chapterStart: range.lowerBound, chapterEnd: range.upperBound, chapters: chapters)
        }
        var input = NativePlaybackBenchmarkInput(schemaVersion: 1, phase: "candidate", baselineExecutablePath: nil, books: books)
        XCTAssertThrowsError(try input.validateRequestedBooks(), "Named synthetic fixtures must not impersonate requested books")
        try input.validateScope()
        let roundTrip = try JSONDecoder().decode(NativePlaybackBenchmarkInput.self, from: JSONEncoder().encode(input))
        let report = try NativePlaybackBenchmarkReport(input: roundTrip)
        let executable = try XCTUnwrap(Bundle.main.executableURL).resolvingSymlinksInPath()
        let payload = executable.deletingLastPathComponent()
            .appendingPathComponent(executable.lastPathComponent + ".debug.dylib")
        let code = FileManager.default.isReadableFile(atPath: payload.path) ? payload : executable
        XCTAssertEqual(report.appCodeSHA256, try NativePlaybackBenchmarkInput.hash(code.path))
        try roundTrip.validateScope()
        try roundTrip.validateFiles()
        XCTAssertEqual(try NativePlaybackBenchmarkInput.hash(books[0].chapters[0].path), books[0].chapters[0].sha256)
        try Data("changed fixture bytes".utf8).write(to: URL(fileURLWithPath: books[0].chapters[0].path))
        XCTAssertThrowsError(try roundTrip.validateFiles())
        input.books[0].chapterEnd = 10
        XCTAssertThrowsError(try input.validateScope())
        input.books[0] = books[0]
        input.books[0].chapters.append(books[0].chapters[0])
        XCTAssertThrowsError(try input.validateScope())
    }

    @MainActor
    func testOptInExistingChapterPlaybackLatencyAndMemory() async throws {
        let input = try NativePlaybackBenchmarkInput.optIn()
        var report = try NativePlaybackBenchmarkReport(input: input)
        let identifier = "NativePlaybackBenchmark-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey, AudioPlayer.currentBookIDDefaultsKey,
                    AudioPlayer.currentChapterIndexDefaultsKey, AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey, AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let saved = keys.map { standard.object(forKey: $0) }
        let widget = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        let previousWidgetBook = widget?.object(forKey: "currentlyPlayingBookId")
        widget?.set("", forKey: "currentlyPlayingBookId")
        defer {
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            widget?.set(previousWidgetBook, forKey: "currentlyPlayingBookId")
            defaults.removePersistentDomain(forName: identifier)
            do { add(try report.attachment("native-existing-audio-benchmark.json")) }
            catch { XCTFail("Could not attach playback measurements: \(error)") }
        }
        for book in input.books {
            let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
            defer { player.stop() }
            let knownIDs = Set(LatencyObservationStore.shared.snapshot().map(\.id))
            let chapters = try await book.chapters.asyncBenchmarkChapters()
            let snapshot = JobSnapshot(jobId: UUID().uuidString, state: "finished", bookTitle: book.name, bookAuthor: nil,
                coverUrl: nil, coverMimeType: nil, engine: nil, voice: nil, language: nil,
                progressPercent: 100, chaptersTotal: 2, chaptersCompleted: 2, chapterProgress: chapters,
                outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
            standard.set(identifier, forKey: ReaderSessionState.currentlyReadingBookIDKey)
            standard.set(identifier, forKey: AudioPlayer.currentBookIDDefaultsKey)
            let started = DispatchTime.now().uptimeNanoseconds
            report.points.append(.capture(book: book.name, event: "before_play", started: started))
            player.play(snapshot: snapshot, restoreAutoplay: false)
            player.resume()
            try await benchmarkWait {
                player.positionSeconds > 0 && LatencyObservationStore.shared.snapshot().contains {
                    !knownIDs.contains($0.id) && $0.records.contains { $0.transition == .audioAudible }
                }
            }
            report.points.append(.capture(book: book.name, event: "first_progressing_audio", started: started,
                                          journeys: LatencyObservationStore.shared.snapshot().filter { !knownIDs.contains($0.id) }))
            player.pause()
            for (event, expectedIndex, target) in [("seek", 0, 2.0), ("next_chapter", 1, 0.0), ("previous_chapter", 0, 0.0)] {
                let actionStart = DispatchTime.now().uptimeNanoseconds
                if event == "seek" { player.seek(to: target) }
                else if event == "next_chapter" { player.nextChapter() }
                else { player.previousChapter() }
                try await benchmarkWait {
                    guard let item = player.testHook_currentPlayerItem(), let asset = item.asset as? AVURLAsset else { return false }
                    let time = item.currentTime().seconds
                    return !player.isSeeking && asset.url == URL(fileURLWithPath: book.chapters[expectedIndex].path)
                        && item.status == .readyToPlay && time.isFinite
                        && (event != "seek" || abs(time - target) < 0.1)
                }
                XCTAssertFalse(player.isPlaying, "Paused navigation must not autoplay.")
                report.points.append(.capture(book: book.name, event: event, started: actionStart,
                                              journeys: LatencyObservationStore.shared.snapshot().filter { !knownIDs.contains($0.id) }))
            }
        }
        report.status = "completed"
    }

    @MainActor
    private func benchmarkWait(_ ready: () -> Bool) async throws {
        for _ in 0..<200 {
            if ready() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NativePlaybackBenchmarkInput.invalid("Real AVPlayer readiness timed out; do not report a latency success")
    }

    @MainActor
    func testPlaybackAndSeekKeepJourneyDiagnosticsLocalByDefault() async throws {
#if os(iOS)
        let sessionTrace = AudioSessionEventTrace()
        let session = AVAudioSession.sharedInstance()
        let sessionObservers = [
            (AVAudioSession.interruptionNotification, AVAudioSessionInterruptionTypeKey),
            (AVAudioSession.routeChangeNotification, AVAudioSessionRouteChangeReasonKey),
        ].map { name, key in
            NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { note in
                let value = (note.userInfo?[key] as? NSNumber)?.intValue ?? -1
                let reason = (note.userInfo?[AVAudioSessionInterruptionReasonKey] as? NSNumber)?.intValue ?? -1
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.intValue ?? -1
                sessionTrace.append("\(name.rawValue)=\(value):reason=\(reason):options=\(options)")
            }
        }
        defer { sessionObservers.forEach { NotificationCenter.default.removeObserver($0) } }
#endif
        let identifier = "ObservationPrivacy-\(UUID().uuidString)"
        let host = "\(UUID().uuidString.lowercased()).invalid"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let saved = keys.map { standard.object(forKey: $0) }
        let widgetDefaults = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        let savedWidgetBook = widgetDefaults?.object(forKey: "currentlyPlayingBookId")
        widgetDefaults?.set("", forKey: "currentlyPlayingBookId")
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(identifier).wav")
        ObservationPrivacyProtocol.configure(host: host)
        XCTAssertTrue(URLProtocol.registerClass(ObservationPrivacyProtocol.self))
        defer {
            URLProtocol.unregisterClass(ObservationPrivacyProtocol.self)
            ObservationPrivacyProtocol.configure(host: "")
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            widgetDefaults?.set(savedWidgetBook, forKey: "currentlyPlayingBookId")
            defaults.removePersistentDomain(forName: identifier)
            try? FileManager.default.removeItem(at: audioURL)
        }

        // A zero-request assertion is meaningful only if the shared-session
        // interception has first proved that it sees requests from this host.
        let baseURL = try XCTUnwrap(URL(string: "https://\(host)/"))
        var probe = URLRequest(url: baseURL.appendingPathComponent("privacy-probe"))
        probe.timeoutInterval = 3
        _ = try await URLSession.shared.data(for: probe)
        XCTAssertEqual(ObservationPrivacyProtocol.capturedRequests().map { $0.url?.path }, ["/privacy-probe"])

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 120_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(buffer.frameLength) {
            samples[frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 8_000)) * 0.01
        }
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            try file.write(from: buffer)
        }
        let player = AudioPlayer(
            resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)),
            backendBaseURL: baseURL)
        defer { player.stop() }
        standard.set(identifier, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        standard.set(identifier, forKey: AudioPlayer.currentBookIDDefaultsKey)
        let originalIDs = Set(LatencyObservationStore.shared.snapshot().map(\.id))
        let snapshot = JobSnapshot(
            jobId: identifier, state: "finished", bookTitle: "Local privacy fixture", bookAuthor: nil,
            coverUrl: nil, coverMimeType: nil, engine: nil, voice: nil, language: "en",
            progressPercent: 100, chaptersTotal: 1, chaptersCompleted: 1,
            chapterProgress: [.init(index: 0, name: "Chapter", status: "completed",
                downloadUrl: audioURL.absoluteString, chars: 100, charsProcessed: 100,
                progressRatio: 1, durationSeconds: 15, startedAt: nil, completedAt: nil)],
            outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
        player.play(snapshot: snapshot, startingAt: 0)
#if os(iOS)
        sessionTrace.append("resumeRequested")
#endif
        player.resume()
        for _ in 0..<100 {
            if player.positionSeconds > 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let item = player.testHook_currentPlayerItem()
        let itemError = item?.error as NSError?
        var sessionState = ""
#if os(iOS)
        sessionState = " sessionEvents=\(sessionTrace.snapshot())"
#endif
        XCTAssertGreaterThan(player.positionSeconds, 0,
            "The local fixture must actually advance. "
            + "itemTime=\(item?.currentTime().seconds ?? -1) status=\(item?.status.rawValue ?? -1) "
            + "playing=\(player.isPlaying) duration=\(player.durationSeconds) "
            + "empty=\(item?.isPlaybackBufferEmpty ?? false) "
            + "error=\(itemError?.domain ?? "none"):\(itemError?.code ?? 0)\(sessionState)")
        player.seek(to: 2)
        for _ in 0..<100 {
            let reached = LatencyObservationStore.shared.snapshot().contains { journey in
                !originalIDs.contains(journey.id) && journey.kind == .seek &&
                    journey.records.contains { $0.transition == .seekTargetReached }
            }
            if reached { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        player.pause()
        // Allow already scheduled URLSession work to reach the interceptor.
        try await Task.sleep(nanoseconds: 500_000_000)
        let exported = try JSONDecoder().decode([LatencyObservation.Journey].self,
                                               from: LatencyObservationStore.shared.exportData())
        let journeys = exported.filter { !originalIDs.contains($0.id) }
        let playback = journeys.filter { $0.kind == .progressivePlayback }.flatMap(\.records).map(\.transition)
        let seeks = journeys.filter { $0.kind == .seek }.flatMap(\.records).map(\.transition)
        XCTAssertTrue(playback.contains(.playRequested))
        XCTAssertTrue(playback.contains(.audioQueued))
        XCTAssertTrue(playback.contains(.audioAudible))
        XCTAssertTrue(seeks.contains(.seekRequested))
        XCTAssertTrue(seeks.contains(.seekTargetReached))
        let diagnosticRequests = ObservationPrivacyProtocol.capturedRequests().filter {
            $0.url?.lastPathComponent == "journey-observations"
        }
        XCTAssertTrue(diagnosticRequests.isEmpty, "Routine playback must not upload local journey diagnostics.")
    }
}

private extension Array where Element == NativePlaybackBenchmarkInput.Chapter {
    func asyncBenchmarkChapters() async throws -> [JobSnapshot.Chapter] {
        var chapters: [JobSnapshot.Chapter] = []
        for (offset, input) in enumerated() {
            let asset = AVURLAsset(url: URL(fileURLWithPath: input.path))
            let playable = try await asset.load(.isPlayable)
            let time = try await asset.load(.duration)
            let duration = time.seconds
            guard playable, duration.isFinite, duration > 2 else {
                throw NativePlaybackBenchmarkInput.invalid("Existing MP3 must be playable and longer than the seek target")
            }
            chapters.append(.init(index: offset, name: "source-\(input.sourceIndex)", status: "completed",
                downloadUrl: URL(fileURLWithPath: input.path).absoluteString, chars: 0, charsProcessed: 0,
                progressRatio: 1, durationSeconds: duration, startedAt: nil, completedAt: nil))
        }
        return chapters
    }
}
#endif
