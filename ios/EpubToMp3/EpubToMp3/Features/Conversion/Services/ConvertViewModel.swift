import Foundation

@MainActor
final class ConvertViewModel {
    let session: ManualConversionSession

    init(session: ManualConversionSession? = nil) {
        self.session = session ?? ManualConversionSession()
    }
    var selectedFile: URL?
    var engine = TtsSelection.piperEngine
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
    var recoverySelection: TtsRecoveryCandidate?
    var recoveryLanguage: String?

    var manualPrimary: TtsSelection {
        let trimmedVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        return TtsSelection(engine: engine, modelID: TtsSelection.defaultModelID(forEngine: engine),
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

    func submit(player: AudioPlayer? = nil) async {
        guard !isSubmitting else { return }
        guard let file = selectedFile else {
            session.reportValidationFailure(L10n.string("convert.error.pickFileFirst"))
            return
        }
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
                modelID: TtsSelection.defaultModelID(forEngine: engine),
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
                    policyVersion: allowSecondary ? inheritedPreferences?.policyVersion : nil,
                    footnoteNarration: inheritedPreferences?.footnoteNarration)
            }
            if let recoverySelection, let recoveryLanguage {
                options = options.recovering(with: recoverySelection, language: recoveryLanguage)
                self.recoverySelection = nil
                self.recoveryLanguage = nil
            }
            await session.run(file: file, start: chapterRange.start, end: chapterRange.end, options: options)
        } catch {
            session.reportValidationFailure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Content identity of a picked file, read inside its own security scope. The scope taken
    /// for the conversion ends when `submit` returns, and a file picked in place (Files, iCloud)
    /// cannot be read without one, so the language recovery must not hash outside it.
    nonisolated static func sourceIdentity(
        of file: URL,
        startScope: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopScope: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
        hash: (URL) throws -> String = { try BookContentIdentity.hash(of: $0) }
    ) throws -> String {
        let started = startScope(file)
        defer { if started { stopScope(file) } }
        return try hash(file)
    }

#if os(macOS)
    /// Copies a selected document into an app-owned inbox with a balanced
    /// security-scoped access lifetime.
    nonisolated static func importForConversion(
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

    /// Removes the staging directory of a copy made by `importForConversion`.
    /// Only a file exactly one level below the inbox is touched, so a library
    /// book or any user file passed here is never deleted.
    nonisolated static func discardImportedCopy(
        _ file: URL,
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil
    ) {
        guard let inbox = try? conversionInboxDirectory(fileManager: fileManager, baseDirectory: baseDirectory)
        else { return }
        let staging = file.deletingLastPathComponent()
        guard staging.deletingLastPathComponent().standardizedFileURL.path == inbox.standardizedFileURL.path,
              UUID(uuidString: staging.lastPathComponent) != nil else { return }
        try? fileManager.removeItem(at: staging)
    }

    nonisolated static func conversionInboxDirectory(
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
