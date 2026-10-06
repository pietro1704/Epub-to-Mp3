#if canImport(AVFoundation) && canImport(MediaPlayer)
import AVFoundation
import Foundation
import XCTest
@testable import EpubToMp3

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
#endif
