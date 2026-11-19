import Foundation
import os.log

/// Builds the `ConversionOptions` a narration request sends to Rust from the
/// saved speech preferences.
///
/// The bundled catalog pins each selection to its model or provider session
/// for this platform. When the catalog cannot be read the selections are sent
/// as chosen, so conversion still starts, and the failure is reported instead
/// of being dropped.
enum NarrationConversionOptions {
    struct Prepared {
        let options: ConversionOptions
        /// Why the selections were sent without catalog capture; `nil` when captured.
        let catalogFailure: Error?
    }

    #if os(macOS)
    static let platformTarget = "macos"
    #else
    static let platformTarget = "ios"
    #endif

    private static let log = Logger(subsystem: "epub2mp3", category: "Conversion")

    /// Options for `preferences` from the bundled converter, logging a catalog failure.
    static func current(for preferences: TtsPreferences) -> ConversionOptions {
        let prepared = prepare(preferences)
        if let failure = prepared.catalogFailure {
            log.error("""
                TTS catalog unavailable; sending the saved voices without catalog capture: \
                \(String(describing: failure), privacy: .public)
                """)
        }
        return prepared.options
    }

    static func prepare(
        _ preferences: TtsPreferences,
        loadCatalog: () throws -> TtsCatalog = { try ConverterFFIAdapter().ttsCatalog() },
        modelsRoot: URL? = LocalSpeechModelReadiness.ttsModelsRoot(),
        espeakDataDirectory: String? = Bundle.main.resourceURL?.path,
        target: String = platformTarget
    ) -> Prepared {
        var options = ConversionOptions.selectedEngine(preferences.primary.engine, modelsRoot: modelsRoot)
        var catalogFailure: Error?
        do {
            options.ttsPreferences = try loadCatalog().capture(preferences, target: target)
        } catch {
            options.ttsPreferences = preferences
            catalogFailure = error
        }
        options.modelsRoot = modelsRoot?.path
        options.espeakDataDirectory = espeakDataDirectory
        return Prepared(options: options, catalogFailure: catalogFailure)
    }
}
