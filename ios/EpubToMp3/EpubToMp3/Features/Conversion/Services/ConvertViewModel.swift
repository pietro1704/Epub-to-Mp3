import Foundation

@MainActor
final class ConvertViewModel {
    typealias ConversionExecutor = @MainActor (URL, Int32, Int32, ConversionOptions?) async throws -> RustConversionCoordinator.Result
    private let converter: ConversionExecutor

    init(converter: @escaping ConversionExecutor = { file, start, end, options in
        try await RustConversionCoordinator().convert(bookURL: file, chapterStart: start, chapterEnd: end, options: options)
    }) {
        self.converter = converter
    }
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

    static func parseChapterSelection(_ input: String) throws -> (start: Int32, end: Int32) {
        do {
            return try ConversionChapterSelection.parse(input)
        } catch {
            throw EmbeddedConverterError.conversionFailed(L10n.string("convert.error.invalidChapterRange"))
        }
    }

    func submit(
        client: APIClient? = nil,
        useEmbeddedRuntime: Bool = false,
        player: AudioPlayer? = nil
    ) async {
        guard !isSubmitting else { return }
        guard let file = selectedFile else {
            error = L10n.string("convert.error.pickFileFirst")
            return
        }
        // Keep the legacy parameters source-compatible for callers during the
        // migration, but never resolve or use an HTTP client on Apple.
        _ = client
        _ = useEmbeddedRuntime
        _ = player // Manual conversion never owns or changes the playback session.

        isSubmitting = true
        error = nil
        submittedJobId = nil
        defer { isSubmitting = false }

        do {
            let chapterRange = try Self.parseChapterSelection(chapters)
#if os(iOS)
            let accessing = file.startAccessingSecurityScopedResource()
            defer { if accessing { file.stopAccessingSecurityScopedResource() } }
            _ = accessing
#endif
            let options = ConversionOptions(
                engine: engine,
                voice: voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : voice,
                language: language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : language,
                clearCache: clearCache,
                forceReprocess: forceReprocess,
                maxPerformance: maxPerformance
            )
            let result = try await converter(file, chapterRange.start, chapterRange.end, options)
            submittedJobId = result.jobID
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
        let staging = inbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let name = url.lastPathComponent.isEmpty ? "Book" : url.lastPathComponent
        let destination = staging.appendingPathComponent(name, isDirectory: false)
        do {
            try fileManager.copyItem(at: url, to: destination)
        } catch {
            // Only this import owns staging; prior inbox inputs remain usable.
            try? fileManager.removeItem(at: staging)
            throw error
        }
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
