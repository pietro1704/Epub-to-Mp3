import Foundation

/// Local conversion entry point shared by the Apple clients.
///
/// This type deliberately has no transport or backend dependency. The Rust
/// FFI owns EPUB parsing, model selection, conversion, and artifact creation.
final class RustConversionCoordinator {
    struct Result: Sendable {
        let jobID: String
        let manifestJSON: Data
        let outputDirectory: URL

        func snapshot() throws -> JobSnapshot {
            let envelope = try JSONDecoder().decode(Envelope.self, from: manifestJSON)
            let chapters = envelope.manifest.chapters.enumerated().map { offset, chapter in
                JobSnapshot.Chapter(
                    index: offset,
                    name: chapter.title,
                    status: "completed",
                    downloadUrl: outputDirectory.appendingPathComponent(chapter.filename).path,
                    chars: chapter.textChars,
                    charsProcessed: chapter.textChars,
                    progressRatio: 1,
                    durationSeconds: nil,
                    startedAt: nil,
                    completedAt: nil
                )
            }
            return JobSnapshot(
                jobId: envelope.manifest.jobId,
                state: "finished",
                bookTitle: envelope.manifest.title,
                bookAuthor: envelope.manifest.author,
                coverUrl: envelope.manifest.cover.map { outputDirectory.appendingPathComponent($0).path },
                coverMimeType: nil,
                engine: nil,
                voice: nil,
                language: nil,
                progressPercent: 100,
                chaptersTotal: chapters.count,
                chaptersCompleted: chapters.count,
                chapterProgress: chapters,
                outputs: nil,
                logUrl: nil,
                error: nil,
                lastActivityAt: Date().timeIntervalSince1970
            )
        }
    }

    private struct Envelope: Decodable {
        let manifest: Manifest
    }
    private struct Manifest: Decodable {
        let jobId: String
        let title: String
        let author: String
        let chapters: [Chapter]
        let cover: String?
    }
    private struct Chapter: Decodable {
        let title: String?
        let filename: String
        let textChars: Int
    }

    private let adapter: ConverterFFIAdapter
    private let fileManager: FileManager

    init(
        adapter: ConverterFFIAdapter = ConverterFFIAdapter(),
        fileManager: FileManager = .default
    ) {
        self.adapter = adapter
        self.fileManager = fileManager
    }

    func convert(
        bookURL: URL,
        jobID: String = UUID().uuidString,
        chapterStart: Int32 = -1,
        chapterEnd: Int32 = -1
    ) async throws -> Result {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let outputDirectory = root
            .appendingPathComponent("EpubToMp3", isDirectory: true)
            .appendingPathComponent("RustConversions", isDirectory: true)
            .appendingPathComponent(jobID, isDirectory: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let logURL = outputDirectory.appendingPathComponent("conversion.log")
        try? Data("[Rust] conversion started: \(bookURL.lastPathComponent)\n".utf8).write(to: logURL)

        do {
            let manifest = try await Task.detached(priority: .userInitiated) {
                try self.adapter.convertBook(
                    at: bookURL,
                    outputDirectory: outputDirectory,
                    chapterStart: chapterStart,
                    chapterEnd: chapterEnd
                )
            }.value
            if let existing = try? String(contentsOf: logURL, encoding: .utf8) {
                try? Data((existing + "[Rust] conversion finished\n").utf8).write(to: logURL)
            }
            return Result(jobID: jobID, manifestJSON: manifest, outputDirectory: outputDirectory)
        } catch {
            if let existing = try? String(contentsOf: logURL, encoding: .utf8) {
                try? Data((existing + "[Rust] conversion failed: \(error.localizedDescription)\n").utf8).write(to: logURL)
            }
            throw error
        }
    }
}
