import Foundation

@MainActor
final class ConvertViewModel {
    typealias ConversionExecutor = @MainActor (URL, Int32, Int32, ConversionOptions?) async throws -> RustConversionCoordinator.Result
    let session: ManualConversionSession

    init(converter: ConversionExecutor? = nil) {
        if let converter {
            session = ManualConversionSession(executor: { file, _, start, end, options, _, _ in
                try await converter(file, start, end, options)
            })
        } else {
            session = ManualConversionSession()
        }
    }

    init(session: ManualConversionSession) {
        self.session = session
    }
    var selectedFile: URL?
    var engine = "piper"
    var inheritedPreferences: TtsPreferences?
    var usesPreferences = true
    var allowSecondary = false
    var voice = ""
    var language = ""
    var chapters = ""
    var clearCache = false
    var forceReprocess = false
    var maxPerformance = false
    var modelsRoot: String?

    var manualPrimary: TtsSelection {
        let trimmedVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        return TtsSelection(engine: engine, modelID: engine == "piper" ? "pt_BR-faber-medium" : nil,
                            voice: trimmedVoice.isEmpty ? nil : voice)
    }
    var distinctManualSecondary: TtsSelection? {
        inheritedPreferences?.secondary.flatMap { $0 == manualPrimary ? nil : $0 }
    }

    var isSubmitting: Bool { session.isRunning }
    var submittedJobId: String? { session.result?.jobID }
    var error: String? { session.errorMessage }

    func cancel() { session.cancel() }

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
            session.reportValidationFailure(L10n.string("convert.error.pickFileFirst"))
            return
        }
        // Keep the legacy parameters source-compatible for callers during the
        // migration, but never resolve or use an HTTP client on Apple.
        _ = client
        _ = useEmbeddedRuntime
        _ = player // Manual conversion never owns or changes the playback session.

        do {
            let chapterRange = try Self.parseChapterSelection(chapters)
#if os(iOS)
            let accessing = file.startAccessingSecurityScopedResource()
            defer { if accessing { file.stopAccessingSecurityScopedResource() } }
            _ = accessing
#endif
            var options = ConversionOptions(
                engine: engine,
                voice: voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : voice,
                language: language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : language,
                clearCache: clearCache,
                forceReprocess: forceReprocess,
                maxPerformance: maxPerformance,
                modelsRoot: modelsRoot ?? LocalSpeechModelReadiness.ttsModelsRoot()?.path,
                modelID: engine == "piper" ? "pt_BR-faber-medium" : nil,
                espeakDataDirectory: Bundle.main.resourceURL?.path
            )
            if usesPreferences, let inheritedPreferences {
                options.ttsPreferences = inheritedPreferences
                options.engine = inheritedPreferences.primary.engine
                options.modelID = inheritedPreferences.primary.modelID
                options.voice = inheritedPreferences.primary.voice
            } else {
                options.ttsPreferences = TtsPreferences(
                    primary: TtsSelection(engine: engine, modelID: options.modelID, voice: options.voice),
                    secondary: allowSecondary ? distinctManualSecondary : nil,
                    allowOnlineFallback: allowSecondary && distinctManualSecondary != nil && (inheritedPreferences?.allowOnlineFallback ?? false),
                    policyVersion: allowSecondary ? inheritedPreferences?.policyVersion : nil)
            }
            await session.run(file: file, start: chapterRange.start, end: chapterRange.end, options: options)
        } catch {
            session.reportValidationFailure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
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
