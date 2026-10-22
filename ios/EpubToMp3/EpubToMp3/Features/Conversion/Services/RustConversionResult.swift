import Foundation

extension RustConversionCoordinator {
    /// Restore durable Rust output without reopening or synthesizing the book.
    static func persistedSnapshot(jobID: String, fileManager: FileManager = .default) -> JobSnapshot? {
        guard !jobID.isEmpty, jobID != ".", jobID != "..",
              !jobID.contains("/"), !jobID.contains("\\"), !jobID.contains("\0"),
              let root = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                             appropriateFor: nil, create: false) else { return nil }
        let directory = root.appendingPathComponent("EpubToMp3", isDirectory: true)
            .appendingPathComponent("RustConversions", isDirectory: true)
            .appendingPathComponent(jobID, isDirectory: true)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.jobId == jobID, !manifest.chapters.isEmpty else { return nil }
        let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var indices = Set<Int>()
        for (offset, chapter) in manifest.chapters.enumerated() {
            let index = chapter.sourceIndex ?? offset
            guard index >= 0, indices.insert(index).inserted,
                  !chapter.filename.isEmpty, !chapter.filename.hasPrefix("/"),
                  !chapter.filename.contains("\0") else { return nil }
            let url = directory.appendingPathComponent(chapter.filename).resolvingSymlinksInPath()
            guard url.standardizedFileURL.path.hasPrefix(directoryPath),
                  let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.int64Value > 0 else { return nil }
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let envelope = try? JSONSerialization.data(withJSONObject: ["manifest": object]) else { return nil }
        return try? Result(jobID: jobID, manifestJSON: envelope, outputDirectory: directory).snapshot()
    }

    struct Result: Sendable {
        let jobID: String
        let manifestJSON: Data
        let outputDirectory: URL

        func validateSelectedChapters(_ positions: ClosedRange<Int>) throws {
            let envelope = try JSONDecoder().decode(Envelope.self, from: manifestJSON)
            guard envelope.manifest.jobId == jobID else {
                throw EmbeddedConverterError.conversionFailed("Rust returned a different conversion job ID.")
            }
            // Count alone cannot distinguish the requested chapters from an
            // equally sized, duplicated or reordered selection. Scoped jobs
            // require the explicit source identity emitted by the Rust worker.
            let actual = envelope.manifest.chapters.map(\.sourceIndex)
            let expected = positions.map { Optional($0) }
            guard actual == expected else {
                throw EmbeddedConverterError.conversionFailed(
                    "Rust chapter identities do not match the selected range \(positions.lowerBound)...\(positions.upperBound)."
                )
            }
        }

        func snapshot() throws -> JobSnapshot {
            let envelope = try JSONDecoder().decode(Envelope.self, from: manifestJSON)
            guard envelope.manifest.jobId == jobID else {
                throw EmbeddedConverterError.conversionFailed(
                    "Rust returned job ID \(envelope.manifest.jobId) for request \(jobID)."
                )
            }
            let chapters = envelope.manifest.chapters.enumerated().map { offset, chapter in
                JobSnapshot.Chapter(
                    index: chapter.sourceIndex ?? offset,
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
                engine: envelope.manifest.usedSelections.map { Array(Set($0.map(\.engine))).sorted().joined(separator: " + ") },
                voice: envelope.manifest.usedSelections.map { $0.compactMap { $0.modelID ?? $0.voice }.joined(separator: " + ") },
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
        let ttsPreferences: TtsPreferences?
        let usedSelections: [TtsSelection]?
    }
    private struct Chapter: Decodable {
        let title: String?
        let filename: String
        let textChars: Int
        let sourceIndex: Int?
    }

}
