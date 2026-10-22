import AVFoundation
import Darwin
import Foundation
import XCTest

@testable import EpubToMp3

extension DeviceConversionBenchmarkTests {
    @MainActor
    func testOptInDeviceConversionBenchmark() async throws {
        guard let json = ProcessInfo.processInfo.environment["EPUB2MP3_DEVICE_BENCHMARK_SPEC"] else {
            throw XCTSkip("Set EPUB2MP3_DEVICE_BENCHMARK_SPEC to an explicit benchmark JSON specification.")
        }
        let manager = FileManager.default
        let temporaryRoot = manager.temporaryDirectory.resolvingSymlinksInPath()
        let spec = try JSONDecoder().decode(DeviceBenchmarkSpec.self, from: Data(json.utf8))
        try require(UUID(uuidString: spec.runID) != nil, "Invalid report run UUID.")
        let reportURL = temporaryRoot.appendingPathComponent("DeviceBenchmarkReports/\(spec.runID).json")
        var report = DeviceBenchmarkReport(runID: spec.runID, cases: spec.cases.map {
            .init(bookPath: $0.bookPath, chapterStart: $0.chapterStart, chapterEnd: $0.chapterEnd)
        })
        var ownedInputs: BenchmarkInputCopies?
        var activeCase: Int?
        var phase = "scope validation"
        defer {
            if let ownedInputs {
                do { try manager.removeItem(at: ownedInputs.directory) }
                catch {
                    report.recordFailure(error, context: "App-owned input cleanup")
                    XCTFail("Could not remove app-owned benchmark inputs: \(error)")
                }
            }
            do {
                _ = try report.save(to: reportURL)
            } catch {
                report.recordFailure(error, context: "Report persistence")
                XCTFail("Could not persist benchmark report: \(error)")
            }
            do {
                let data = try report.encoded()
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "device-benchmark-report.json"
                attachment.lifetime = .keepAlways
                add(attachment)
            } catch {
                XCTFail("Could not attach benchmark report: \(error)")
            }
        }
        do {
            _ = try report.save(to: reportURL)
            try spec.validate(temporaryRoot: temporaryRoot)
            let copies = try BenchmarkInputCopies()
            ownedInputs = copies
            var bookURLs: [URL] = []
            let adapter = ConverterFFIAdapter()
            let isolatedManager = BenchmarkFileManager(supportRoot: copies.directory)
            let outputStore = RustConversionOutputStore(
                root: copies.directory.appendingPathComponent("EpubToMp3/RustConversions", isDirectory: true),
                notificationCenter: NotificationCenter())
            let coordinator = RustConversionCoordinator(adapter: adapter, fileManager: isolatedManager, outputStore: outputStore)
            let outputs = spec.cases.map {
                copies.directory.appendingPathComponent("EpubToMp3/RustConversions/\($0.jobID)", isDirectory: true)
            }
            // Preflight every case before the first synthesis, including metadata bounds.
            for (index, selection) in spec.cases.enumerated() {
                activeCase = index
                phase = "input copy and metadata preflight"
                let source = temporaryRoot.appendingPathComponent(selection.bookPath)
                try require(manager.isReadableFile(atPath: source.path), "Staged EPUB is unreadable: \(selection.bookPath)")
                let bookURL = try copies.copy(source: source, index: index)
                bookURLs.append(bookURL)
                let output = outputs[index]
                try require(!manager.fileExists(atPath: output.path)
                            && (try? manager.destinationOfSymbolicLink(atPath: output.path)) == nil,
                            "Benchmark output already exists; audio reuse is forbidden.")
                try validateBenchmarkOutputParent(output)
                let book = try adapter.openBook(at: bookURL)
                let metadata = try JSONSerialization.jsonObject(with: book.metadataJSON) as? [String: Any]
                guard let chapters = metadata?["chapters"] as? [[String: Any]], !chapters.isEmpty else {
                    throw BenchmarkFailure("Missing chapter metadata.")
                }
                if selection.chapterStart == -1 {
                    report.cases[index].chaptersRequested = chapters.count
                } else {
                    try require(selection.chapterEnd < chapters.count, "Selected range exceeds book metadata.")
                    report.cases[index].chaptersRequested = selection.chapterEnd - selection.chapterStart + 1
                }
            }
            _ = try report.save(to: reportURL)
            for (index, selection) in spec.cases.enumerated() {
                activeCase = index
                phase = "output reservation"
                let output = outputs[index]
                // The isolated output store exclusively reserves each fresh job directory.
                // The app-owned parent is cleaned even when conversion fails before returning.
                print("[Device benchmark] starting book=\(selection.bookPath) chapters=\(report.cases[index].chaptersRequested)")
                let beforeSynthesis = BenchmarkFootprintSample.capture()
                let delivery = BenchmarkDeliveryRecorder(startedAt: DispatchTime.now().uptimeNanoseconds,
                                                         before: beforeSynthesis)
                let firstDelivery = expectation(description: "First published chapter delivered for case \(index)")
                let synthesisStart = ProcessInfo.processInfo.systemUptime
                phase = "conversion"
                let result: RustConversionCoordinator.Result
                do {
                    result = try await coordinator.convert(
                        bookURL: bookURLs[index], jobID: selection.jobID,
                        chapterStart: Int32(selection.chapterStart), chapterEnd: Int32(selection.chapterEnd),
                        onProgress: { event in
                            print("[Device benchmark] book=\(selection.bookPath) completed=\(event.chaptersCompleted)/\(event.chaptersTotal) \(event.message)")
                        },
                        onChapterCompleted: { event in
                            let deliveredAt = DispatchTime.now().uptimeNanoseconds
                            if let reason = chapterDeliveryRejection(event, jobID: selection.jobID,
                                start: selection.chapterStart, end: selection.chapterEnd,
                                output: output, manager: manager) {
                                delivery.measurements.rejectedChapterDeliveries.append(reason)
                                print("[Device benchmark] rejected chapter=\(event.chapterIndex): \(reason)")
                                return
                            }
                            if delivery.record(chapterIndex: event.chapterIndex, deliveredAt: deliveredAt) {
                                firstDelivery.fulfill()
                            }
                        }
                    )
                } catch {
                    report.cases[index].synthesisSeconds = ProcessInfo.processInfo.systemUptime - synthesisStart
                    delivery.measurements.afterSynthesis = BenchmarkFootprintSample.capture()
                    report.cases[index].conversionMeasurements = delivery.measurements
                    report.cases[index].error = error.localizedDescription
                    try? report.cases[index].readTelemetry(output: output)
                    throw error
                }
                report.cases[index].synthesisSeconds = ProcessInfo.processInfo.systemUptime - synthesisStart
                delivery.measurements.afterSynthesis = BenchmarkFootprintSample.capture()
                // The coordinator dispatches callbacks to MainActor tasks; drain delivery
                // independently of synthesis timing before snapshotting measurements.
                phase = "chapter delivery"
                await fulfillment(of: [firstDelivery], timeout: 2)
                report.cases[index].conversionMeasurements = delivery.measurements
                try require(delivery.measurements.firstPlayableChapterIndex != nil,
                            "Missing published chapter delivery callback; rejected=\(delivery.measurements.rejectedChapterDeliveries).")
                _ = try report.save(to: reportURL)
                let verificationStart = ProcessInfo.processInfo.systemUptime
                phase = "audio verification"
                do {
                    let snapshot = try result.snapshot()
                    report.cases[index].engine = snapshot.engine
                    report.cases[index].voice = snapshot.voice
                    report.cases[index].language = snapshot.language
                    report.cases[index].chaptersCompleted = snapshot.chaptersCompleted ?? 0
                    report.cases[index].characters = snapshot.playableChapters.reduce(0) { $0 + ($1.chars ?? 0) }
                    try report.cases[index].readTelemetry(output: output)
                    try require(!report.cases[index].chunkMetrics.isEmpty, "Missing chunk telemetry.")
                    let expected = report.cases[index].chaptersRequested
                    try require(snapshot.state == "finished", "Conversion did not finish.")
                    try require(snapshot.chaptersTotal == expected && snapshot.chaptersCompleted == expected
                                && snapshot.playableChapters.count == expected, "Requested chapter count was not completed.")
                    let indices = selection.chapterStart == -1 ? Array(0..<expected)
                        : Array(selection.chapterStart...selection.chapterEnd)
                    try require(snapshot.playableChapters.map(\.index) == indices, "Unexpected source chapter indices.")
                    try require(indices.contains(try XCTUnwrap(delivery.measurements.firstPlayableChapterIndex)),
                                "Delivered chapter was not part of the verified selection.")
                    try require(result.outputDirectory.standardizedFileURL == output.standardizedFileURL,
                                "Unexpected output job directory.")
                    var verifiedPaths = Set<String>()
                    for chapter in snapshot.playableChapters {
                        let path = try XCTUnwrap(chapter.downloadUrl)
                        let audio = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
                        try require(audio.deletingLastPathComponent() == output.standardizedFileURL
                                    && audio.pathExtension.lowercased() == "mp3"
                                    && verifiedPaths.insert(audio.path).inserted, "Unexpected or duplicate MP3 artifact.")
                        let asset = AVURLAsset(url: audio)
                        let playable = try await asset.load(.isPlayable)
                        let duration = try await asset.load(.duration).seconds
                        try require(playable && duration.isFinite && duration > 0, "MP3 is not playable with positive duration.")
                        report.cases[index].audioDurationSeconds += duration
                    }
                } catch {
                    report.cases[index].verificationSeconds = ProcessInfo.processInfo.systemUptime - verificationStart
                    throw error
                }
                report.cases[index].verificationSeconds = ProcessInfo.processInfo.systemUptime - verificationStart
                _ = try report.save(to: reportURL)
                print("[Device benchmark] verified book=\(selection.bookPath) synthesis=\(report.cases[index].synthesisSeconds)s verification=\(report.cases[index].verificationSeconds)s")
            }
            report.status = "passed"
        } catch {
            report.recordFailure(error, context: phase, caseIndex: activeCase)
            print("[Device benchmark] failed phase=\(phase) error=\(error)")
            throw error
        }
    }
}
