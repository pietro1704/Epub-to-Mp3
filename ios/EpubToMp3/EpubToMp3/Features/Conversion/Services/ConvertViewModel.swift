import Foundation

@MainActor
final class ConvertViewModel {
    var selectedFile: URL?
    var engine = "edge"
    var voice = ""
    var language = ""
    var chapters = ""
    var clearCache = false
    var forceReprocess = false
    var maxPerformance = false

    var isSubmitting = false
    var submittedJobId: String?
    var embeddedSnapshot: JobSnapshot?
    var error: String?

    func submit(
        client: APIClient?,
        useEmbeddedRuntime: Bool = false,
        player: AudioPlayer? = nil
    ) async {
        guard let file = selectedFile else {
            error = L10n.string("convert.error.pickFileFirst")
            return
        }
        let canUseEmbeddedRuntime = useEmbeddedRuntime
            && !BookFileType.detect(from: file).requiresServerConversion
        guard canUseEmbeddedRuntime || client != nil else {
            error = L10n.string("convert.error.engineWarmingUp")
            return
        }

        isSubmitting = true
        error = nil
        submittedJobId = nil
        embeddedSnapshot = nil
        defer { isSubmitting = false }

        do {
            var options = APIClient.ConvertOptions()
            options.engine = engine
            if !voice.isEmpty { options.voice = voice }
            if !language.isEmpty { options.language = language }
            if !chapters.isEmpty { options.chapters = chapters }
            options.clearCache = clearCache
            options.forceReprocess = forceReprocess
            options.maxPerformance = maxPerformance
            if canUseEmbeddedRuntime {
                let bookID = "conversion-\(UUID().uuidString)"
                let snapshot: JobSnapshot
                if let player {
                    snapshot = try await EmbeddedConversionCoordinator.stream(
                        bookURL: file,
                        bookID: bookID,
                        engine: options.engine,
                        voice: options.voice ?? "auto",
                        language: options.language,
                        clearCache: options.clearCache,
                        forceReprocess: options.forceReprocess,
                        maxPerformance: options.maxPerformance,
                        player: player
                    )
                } else {
                    snapshot = try await EmbeddedConversionCoordinator.convert(
                        bookURL: file,
                        bookID: bookID,
                        engine: options.engine,
                        voice: options.voice ?? "auto",
                        language: options.language,
                        clearCache: options.clearCache,
                        forceReprocess: options.forceReprocess,
                        maxPerformance: options.maxPerformance
                    )
                }
                embeddedSnapshot = snapshot
                submittedJobId = snapshot.jobId
                return
            }
#if os(macOS)
            submittedJobId = try await client!.submitConversion(
                localPath: file,
                options: options
            ).jobId
#else
            let accessing = file.startAccessingSecurityScopedResource()
            defer { if accessing { file.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            submittedJobId = try await client!.submitConversion(
                uploadedFile: (data: data, filename: file.lastPathComponent),
                options: options
            ).jobId
#endif
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

#if os(macOS)
    /// Copies a selected document into an app-owned inbox with a balanced
    /// security-scoped access lifetime.
    static func importForConversion(
        _ url: URL,
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil
    ) throws -> URL {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let inbox = try conversionInboxDirectory(
            fileManager: fileManager,
            baseDirectory: baseDirectory
        )
        if fileManager.fileExists(atPath: inbox.path) {
            try fileManager.removeItem(at: inbox)
        }
        try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)

        let name = url.lastPathComponent.isEmpty ? "Book" : url.lastPathComponent
        let destination = inbox.appendingPathComponent(name, isDirectory: false)
        try fileManager.copyItem(at: url, to: destination)
        return destination
    }

    static func conversionInboxDirectory(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil
    ) throws -> URL {
        if let baseDirectory { return baseDirectory }
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appendingPathComponent("EpubToMp3", isDirectory: true)
            .appendingPathComponent("ConversionInbox", isDirectory: true)
    }
#endif
}
