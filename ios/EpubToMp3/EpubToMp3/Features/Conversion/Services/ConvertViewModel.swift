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
    var error: String?

    func submit(client: APIClient?) async {
        guard let client else {
            error = L10n.string("convert.error.engineWarmingUp")
            return
        }
        guard let file = selectedFile else {
            error = L10n.string("convert.error.pickFileFirst")
            return
        }

        isSubmitting = true
        error = nil
        submittedJobId = nil
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
            submittedJobId = try await client.submitConversion(
                localPath: file,
                options: options
            ).jobId
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
