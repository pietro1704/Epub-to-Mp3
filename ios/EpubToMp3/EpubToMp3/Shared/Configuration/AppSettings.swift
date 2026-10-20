import Foundation
import Combine
import os.log
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Reader appearance choices surfaced in the native reader toolbar.
enum ReaderFontFamily: String, CaseIterable, Identifiable {
    case serif
    case sans
    case mono

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .serif: return L10n.string("font.serif")
        case .sans:  return L10n.string("font.sans")
        case .mono:  return L10n.string("font.mono")
        }
    }
}

enum ReaderTheme: String, CaseIterable, Identifiable {
    case auto
    case light
    case sepia
    case parchment
    case paper
    case dark
    case black
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:      return L10n.string("theme.default")
        case .light:     return L10n.string("theme.light")
        case .sepia:     return L10n.string("theme.sepia")
        case .parchment: return L10n.string("theme.parchment")
        case .paper:     return L10n.string("theme.paper")
        case .dark:      return L10n.string("theme.dark")
        case .black:     return L10n.string("theme.black")
        case .custom:    return L10n.string("theme.custom")
        }
    }

    var preferredColorScheme: ReaderColorScheme? {
        switch self {
        case .auto: return nil
        case .dark, .black: return .dark
        case .light, .sepia, .parchment, .paper: return .light
        case .custom: return nil
        }
    }

    #if canImport(UIKit)
    var previewColors: (background: UIColor, foreground: UIColor) {
        switch self {
        case .auto: return (.systemBackground, .label)
        case .light: return Self.systemColors(style: .light)
        case .sepia: return (UIColor(red: 0.96, green: 0.91, blue: 0.80, alpha: 1), UIColor(red: 0.22, green: 0.16, blue: 0.10, alpha: 1))
        case .parchment: return (UIColor(red: 0.90, green: 0.85, blue: 0.72, alpha: 1), UIColor(red: 0.18, green: 0.14, blue: 0.08, alpha: 1))
        case .paper: return (UIColor(red: 0.98, green: 0.98, blue: 0.95, alpha: 1), UIColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1))
        case .dark: return Self.systemColors(style: .dark)
        case .black: return (.black, .white)
        case .custom: return (.systemBackground, .label)
        }
    }

    private static func systemColors(style: UIUserInterfaceStyle) -> (background: UIColor, foreground: UIColor) {
        let traits = UITraitCollection(userInterfaceStyle: style)
        return (.systemBackground.resolvedColor(with: traits), .label.resolvedColor(with: traits))
    }
    #endif

    #if canImport(AppKit)
    var macOSColors: (background: NSColor, foreground: NSColor) {
        switch self {
        case .auto: return (.textBackgroundColor, .textColor)
        case .light: return Self.systemColors(appearance: .aqua)
        case .sepia: return (NSColor(red: 0.96, green: 0.91, blue: 0.80, alpha: 1), NSColor(red: 0.22, green: 0.16, blue: 0.10, alpha: 1))
        case .parchment: return (NSColor(red: 0.90, green: 0.85, blue: 0.72, alpha: 1), NSColor(red: 0.18, green: 0.14, blue: 0.08, alpha: 1))
        case .paper: return (NSColor(red: 0.98, green: 0.98, blue: 0.95, alpha: 1), NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1))
        case .dark: return Self.systemColors(appearance: .darkAqua)
        case .black: return (.black, .white)
        case .custom: return (.windowBackgroundColor, .labelColor)
        }
    }

    private static func systemColors(appearance name: NSAppearance.Name) -> (background: NSColor, foreground: NSColor) {
        var colors = (background: NSColor.textBackgroundColor, foreground: NSColor.textColor)
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            colors = (NSColor(cgColor: NSColor.textBackgroundColor.cgColor) ?? .textBackgroundColor,
                      NSColor(cgColor: NSColor.textColor.cgColor) ?? .textColor)
        }
        return colors
    }
    #endif
}

enum ReaderColorScheme: Equatable {
    case light
    case dark
}

extension AppSettings {
    /// The reader page and attributed content share one palette. Explicit
    /// light/dark themes resolve Apple's semantic colors in that appearance;
    /// Auto keeps adaptive colors so it follows the host appearance.
    var readerColors: (background: PlatformColor, foreground: PlatformColor, link: PlatformColor) {
        let base: (background: PlatformColor, foreground: PlatformColor)
        if readerTheme == .custom {
            let custom = readerCustomColors
            base = (
                PlatformColor(red: CGFloat(custom.background.0), green: CGFloat(custom.background.1), blue: CGFloat(custom.background.2), alpha: 1),
                PlatformColor(red: CGFloat(custom.foreground.0), green: CGFloat(custom.foreground.1), blue: CGFloat(custom.foreground.2), alpha: 1)
            )
        } else {
            #if canImport(UIKit)
            base = readerTheme.previewColors
            #else
            base = readerTheme.macOSColors
            #endif
        }
        #if canImport(UIKit)
        let link: UIColor
        if let scheme = readerPreferredColorScheme {
            link = UIColor.link.resolvedColor(with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light))
        } else {
            link = .link
        }
        #else
        var link = NSColor.linkColor
        if let scheme = readerPreferredColorScheme {
            NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                link = NSColor(cgColor: NSColor.linkColor.cgColor) ?? .linkColor
            }
        }
        #endif
        return (base.background, base.foreground, link)
    }

    var readerPreferredColorScheme: ReaderColorScheme? {
        guard readerTheme == .custom else { return readerTheme.preferredColorScheme }
        let rgb = readerCustomColors.background
        func linear(_ value: Double) -> Double {
            let channel = min(1, max(0, value))
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
        return luminance < 0.179 ? .dark : .light
    }
}

enum ReaderLayout: String, CaseIterable, Identifiable {
    case paginated
    case scrolling

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .scrolling: return L10n.string("layout.scrolling")
        case .paginated: return L10n.string("layout.paginated")
        }
    }
}

enum ReaderLayoutMetrics {
    static let minimumHorizontalMargin: Double = 8
    static let maximumHorizontalMargin: Double = 80

    static func clampedMargin(_ value: Double) -> Double {
        max(minimumHorizontalMargin, min(maximumHorizontalMargin, value))
    }
}

/// Page-turn animation style for paginated mode. Persisted via
/// `AppSettings.pageTurnStyle`. Default is `.flip` (Apple Books curl).
enum PageTurnStyle: String, CaseIterable, Identifiable {
    case flip
    case slide
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flip:  return L10n.string("pageTurn.flip")
        case .slide: return L10n.string("pageTurn.slide")
        case .none:  return L10n.string("pageTurn.none")
        }
    }
}

/// Horizontal alignment for reader body text. The default `.justified`
/// matches Apple Books and the typographic norm for printed prose;
/// `.left` (ragged-right) suits screens / users who dislike the
/// wide-word-spacing artefacts justification can produce on narrow
/// columns.
enum ReaderTextAlignment: String, CaseIterable, Identifiable {
    case justified
    case left

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .justified: return L10n.string("readerSettings.alignment.justified")
        case .left:      return L10n.string("readerSettings.alignment.left")
        }
    }
}

/// Persisted user preferences. The backend URL drives every API call so the
/// user can point the native client at the canonical Rust HTTP backend.
///
/// Why direct UserDefaults instead of @AppStorage:
/// `@AppStorage` is a `DynamicProperty` tied to a declarative view tree.
/// Storing preferences directly keeps native controllers and Combine
/// observers on the same persistence channel.
/// Plain `@Published` stored properties + `didSet { UserDefaults... }`
/// gives both Combine publishing and persistence on the same channel.
final class AppSettings: ObservableObject {
    static let audioEngineKey = "audioEngine"
    static func ttsModelsRoot(fileManager: FileManager = .default) -> URL? {
        try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("EpubToMp3/TTSModels", isDirectory: true)
    }
    /// Installation UI reports readiness only for a complete catalog installation.
    static func isFaberInstalled(modelsRoot: URL? = ttsModelsRoot(), fileManager: FileManager = .default) -> Bool {
        guard let modelsRoot else { return false }
        let directory = modelsRoot.appendingPathComponent("pt_BR-faber-medium", isDirectory: true)
        guard let metadata = try? Data(contentsOf: directory.appendingPathComponent("metadata.json")),
              let fields = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              fields["id"] as? String == "pt_BR-faber-medium",
              let artifacts = fields["artifacts"] as? [[String: String]] else { return false }
        let expected = [
            "model.onnx": "858555e3a064209c57088fe6bd70c4c3dc54d03eaa00c45d5ecaf43a33f95aa7",
            "model.onnx.json": "7e694de195ae3fc36dd732c445eb04fb49b649854893cb5506b978f0d50a1d6f",
        ]
        return expected.allSatisfy { name, digest in
            guard artifacts.contains(where: { $0["path"] == name && $0["sha256"] == digest }),
                  let attributes = try? fileManager.attributesOfItem(atPath: directory.appendingPathComponent(name).path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let bytes = attributes[.size] as? NSNumber else { return false }
            return bytes.int64Value > 0
        }
    }

    static let playbackForwardSecondsKey = "playbackForwardSeconds"
    static let playbackBackwardSecondsKey = "playbackBackwardSeconds"
    static let playbackSkipIntervals: Set<Double> = [15, 30, 45, 60]
    private let defaults: UserDefaults
    private var loadingPersistedValues = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Conversion is local Rust on every Apple platform. Backend URLs are
        // retained only as inert migration data and never drive production.
        self.backendURL = ""
        self.useEmbeddedRuntime = true
        // Edge is the only network dependency of on-device conversion. Keep
        // it on Wi-Fi by default; the user may opt into cellular explicitly.
        self.allowCellularAudioConversion =
            defaults.object(forKey: "allowCellularAudioConversion") as? Bool ?? false
        self.audioEngine = AudioEnginePreference(
            rawValue: defaults.string(forKey: Self.audioEngineKey) ?? "piper"
        ) ?? .piper
        let storedSecondaryAudioEngine = defaults.string(forKey: "secondaryAudioEngine")
            .flatMap(AudioEnginePreference.init(rawValue:))
        let storedOnlineFallbackConsent = defaults.bool(forKey: "allowOnlineAudioFallback")
        // A missing secondary in old settings may be an explicit no-fallback
        // choice. Only an entirely unconfigured speech policy adopts defaults.
        let hasSavedSpeechPolicy = [Self.audioEngineKey, "secondaryAudioEngine",
                                    "allowOnlineAudioFallback", "ttsPreferencesVersion"]
            .contains { defaults.object(forKey: $0) != nil }
        self.secondaryAudioEngine = hasSavedSpeechPolicy ? storedSecondaryAudioEngine : .system
        if !hasSavedSpeechPolicy {
            defaults.set("piper", forKey: Self.audioEngineKey)
            defaults.set("system", forKey: "secondaryAudioEngine")
            defaults.set(2, forKey: "ttsPreferencesVersion")
        }
        self.allowOnlineAudioFallback = storedOnlineFallbackConsent
        if storedSecondaryAudioEngine == self.audioEngine
            || (!storedOnlineFallbackConsent && storedSecondaryAudioEngine == .edge) {
            self.secondaryAudioEngine = nil
            defaults.removeObject(forKey: "secondaryAudioEngine")
        }
        self.playbackForwardSeconds = Self.validPlaybackSkipInterval(
            defaults.object(forKey: Self.playbackForwardSecondsKey) as? Double
        )
        self.playbackBackwardSeconds = Self.validPlaybackSkipInterval(
            defaults.object(forKey: Self.playbackBackwardSecondsKey) as? Double
        )
        self.readerFontSize = (defaults.object(forKey: "readerFontSize") as? Int) ?? 3
        self.readerFontFamily = ReaderFontFamily(
            rawValue: defaults.string(forKey: "readerFontFamily") ?? ""
        ) ?? .serif
        self.readerTheme = ReaderTheme(
            rawValue: defaults.string(forKey: "readerTheme") ?? ""
        ) ?? .auto
        self.readerAutoScroll = defaults.object(forKey: "readerAutoScroll") as? Bool ?? true
        self.readerShowPageNumbers = defaults.object(forKey: "readerShowPageNumbers") as? Bool ?? true
        self.readerTextAlignment = ReaderTextAlignment(
            rawValue: defaults.string(forKey: "readerTextAlignment") ?? ""
        ) ?? .justified
        // A book opens paginated until the user explicitly chooses another
        // layout. Legacy raw values are not treated as an explicit choice.
        let layoutWasChosen = defaults.bool(forKey: "readerLayout.userSet.v1")
        self.readerLayout = layoutWasChosen
            ? (ReaderLayout(rawValue: defaults.string(forKey: "readerLayout") ?? "") ?? .paginated)
            : .paginated
        self.readerColumns = max(1, min(4, (defaults.object(forKey: "readerColumns") as? Int) ?? 1))
        // UI tests can pin the reader layout regardless of persisted state,
        // e.g. `-uiTestReaderLayout paginated` / `-uiTestReaderLayout scrolling`.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-uiTestReaderFontSize"), i + 1 < args.count,
           let forcedSize = Int(args[i + 1]) {
            self.readerFontSize = max(0, min(4, forcedSize))
        }
        if let i = args.firstIndex(of: "-uiTestReaderLayout"), i + 1 < args.count,
           let forced = ReaderLayout(rawValue: args[i + 1]) {
            self.readerLayout = forced
        }
        if args.contains("-uiTestReaderShowPageNumbers") {
            self.readerShowPageNumbers = true
        }
        self.pageTurnStyle = PageTurnStyle(
            rawValue: defaults.string(forKey: "pageTurnStyle") ?? ""
        ) ?? .flip
        if let i = args.firstIndex(of: "-uiTestPageTurnStyle"), i + 1 < args.count,
           let forced = PageTurnStyle(rawValue: args[i + 1]) {
            self.pageTurnStyle = forced
        }
        self.readerLineSpacing = (defaults.object(forKey: "readerLineSpacing") as? Double) ?? 6
        // The reader keeps an 8pt minimum inside the safe-area content
        // boundary. This leaves a visible gutter without unnecessarily
        // narrowing the reading column on compact iPhones.
        let persistedMargin = (defaults.object(forKey: "readerMargin") as? Double) ?? 16
        self.readerMargin = ReaderLayoutMetrics.clampedMargin(persistedMargin)
        self.readerColumnWidth = (defaults.object(forKey: "readerColumnWidth") as? Double) ?? 720
        self.storedReaderCustomColors =
            defaults.string(forKey: "readerCustomColors") ?? "1,1,1,0,0,0"
        self.readerOverrideFontFamily =
            defaults.object(forKey: "readerOverrideFontFamily") as? Bool ?? false
        self.readerOverrideFontSize =
            defaults.object(forKey: "readerOverrideFontSize") as? Bool ?? false
        if args.contains("-uiTestReaderOverrideFontSize") {
            self.readerOverrideFontSize = true
        }
        self.readerOverrideColours =
            defaults.object(forKey: "readerOverrideColours") as? Bool ?? false
        self.readerBoldOverride =
            defaults.object(forKey: "readerBoldOverride") as? Bool ?? false
        self.readerSuppressItalic =
            defaults.object(forKey: "readerSuppressItalic") as? Bool ?? false
        self.readerLetterSpacing =
            (defaults.object(forKey: "readerLetterSpacing") as? Double) ?? 0
        self.readerWordSpacing =
            (defaults.object(forKey: "readerWordSpacing") as? Double) ?? 0
        loadingPersistedValues = false
        self.offlineCacheBudgetBytes =
            (defaults.object(forKey: "offlineCacheBudgetBytes") as? Int64)
            ?? defaultOfflineCacheBudgetBytes
        self.offlineCacheTTLSeconds =
            (defaults.object(forKey: "offlineCacheTTLSeconds") as? Double)
            ?? defaultOfflineCacheTTLSeconds
    }

    @Published var backendURL: String = "" {
        didSet { defaults.set(backendURL, forKey: "backendURL") }
    }

    /// Master switch: when `true` the app uses its bundled runtime for
    /// everything that *can* run on-device — EPUB parsing (pure Swift +
    /// HTTP backend), TTS conversion (Rust server) —
    /// and treats the configured `backendURL` only as an
    /// optional remote fallback for users who genuinely want it.
    ///
    /// Reader paths NEVER require this to be false. EPUB parsing is
    /// remote (`APIClient` + Rust backend). The flag remains only as a
    /// persisted compatibility key for old installations.
    @Published var useEmbeddedRuntime: Bool = false {
        didSet { defaults.set(useEmbeddedRuntime, forKey: "useEmbeddedRuntime") }
    }

    /// Whether the embedded Edge voice provider may use cellular data.
    /// Defaults to false so local audiobook generation waits for Wi-Fi.
    @Published var allowCellularAudioConversion: Bool = false {
        didSet { defaults.set(allowCellularAudioConversion, forKey: "allowCellularAudioConversion") }
    }

    @Published var audioEngine: AudioEnginePreference = .piper {
        didSet {
            guard !loadingPersistedValues else { return }
            adoptCurrentSpeechPolicyIfEdited()
            defaults.set(audioEngine.rawValue, forKey: Self.audioEngineKey)
            if secondaryAudioEngine == audioEngine { secondaryAudioEngine = nil }
        }
    }

    @Published var secondaryAudioEngine: AudioEnginePreference? = nil {
        didSet {
            guard !loadingPersistedValues else { return }
            adoptCurrentSpeechPolicyIfEdited()
            if secondaryAudioEngine == audioEngine
                || (secondaryAudioEngine == .edge && !allowOnlineAudioFallback) {
                secondaryAudioEngine = nil
                defaults.removeObject(forKey: "secondaryAudioEngine")
                return
            }
            defaults.set(secondaryAudioEngine?.rawValue, forKey: "secondaryAudioEngine")
        }
    }
    @Published var allowOnlineAudioFallback = false {
        didSet {
            guard !loadingPersistedValues else { return }
            adoptCurrentSpeechPolicyIfEdited()
            defaults.set(allowOnlineAudioFallback, forKey: "allowOnlineAudioFallback")
            if !allowOnlineAudioFallback && secondaryAudioEngine == .edge {
                secondaryAudioEngine = nil
            }
        }
    }
    var selectableSecondaryAudioEngines: [AudioEnginePreference] {
        AudioEnginePreference.supportedPreferences.filter {
            $0 != audioEngine && ($0 != .edge || allowOnlineAudioFallback)
        }
    }
    var ttsPreferences: TtsPreferences {
        let secondary = secondaryAudioEngine.flatMap { engine -> TtsSelection? in
            guard engine != .edge || allowOnlineAudioFallback else { return nil }
            return .selected(engine)
        }
        return TtsPreferences(primary: .selected(audioEngine),
                              secondary: secondary,
                              allowOnlineFallback: allowOnlineAudioFallback,
                              policyVersion: (defaults.object(forKey: "ttsPreferencesVersion") as? NSNumber)?.uint32Value)
    }
    private func adoptCurrentSpeechPolicyIfEdited() {
        guard !loadingPersistedValues else { return }
        defaults.set(2, forKey: "ttsPreferencesVersion")
    }
    var conversionOptions: ConversionOptions {
        var options = ConversionOptions.selectedEngine(audioEngine, modelsRoot: Self.ttsModelsRoot())
        options.ttsPreferences = ttsPreferences
        options.modelsRoot = Self.ttsModelsRoot()?.path
        options.espeakDataDirectory = Bundle.main.resourceURL?.path
        return options
    }

    @Published var playbackForwardSeconds: Double = 15 {
        didSet {
            let valid = Self.validPlaybackSkipInterval(playbackForwardSeconds)
            if valid != playbackForwardSeconds {
                playbackForwardSeconds = valid
                return
            }
            defaults.set(playbackForwardSeconds, forKey: Self.playbackForwardSecondsKey)
        }
    }

    @Published var playbackBackwardSeconds: Double = 15 {
        didSet {
            let valid = Self.validPlaybackSkipInterval(playbackBackwardSeconds)
            if valid != playbackBackwardSeconds {
                playbackBackwardSeconds = valid
                return
            }
            defaults.set(playbackBackwardSeconds, forKey: Self.playbackBackwardSecondsKey)
        }
    }

    private static func validPlaybackSkipInterval(_ value: Double?) -> Double {
        guard let value, playbackSkipIntervals.contains(value) else { return 15 }
        return value
    }

    /// True iff the reader and library can render the current book
    /// without a configured backend URL. The reader pipeline is always
    /// local on iOS and macOS through the HTTP backend, so it is always false
    /// until a future offline native implementation exists.
    var canReadOffline: Bool { true }

    /// Backend configuration is always relevant to the production client.
    var remoteBackendControlsEnabled: Bool { false }

    /// 5-step font size scale: 0=XS, 1=S, 2=M (default), 3=L, 4=XL.
    /// Clamped in `didSet` so the rest of the app can trust 0…4.
    @Published var readerFontSize: Int = 3 {
        didSet {
            let clamped = max(0, min(4, readerFontSize))
            if clamped != readerFontSize {
                readerFontSize = clamped
                return  // recursive set will write defaults
            }
            defaults.set(readerFontSize, forKey: "readerFontSize")
        }
    }

    @Published var readerFontFamily: ReaderFontFamily = .serif {
        didSet { defaults.set(readerFontFamily.rawValue, forKey: "readerFontFamily") }
    }

    @Published var readerTheme: ReaderTheme = .light {
        didSet { defaults.set(readerTheme.rawValue, forKey: "readerTheme") }
    }

    @Published var readerAutoScroll: Bool = true {
        didSet { defaults.set(readerAutoScroll, forKey: "readerAutoScroll") }
    }

    /// Whether the "n / total" page indicator renders at the bottom of
    /// each paginated page. Toggle exposed in `ReaderSettingsSheet`.
    /// When false the indicator is hidden AND the paginator's body
    /// budget reclaims the footer's reserved height so the chapter
    /// uses the freed space.
    @Published var readerShowPageNumbers: Bool = true {
        didSet { defaults.set(readerShowPageNumbers, forKey: "readerShowPageNumbers") }
    }

    /// Horizontal alignment for reader body text. Default `.justified`
    /// matches Apple Books and printed-book typography. The renderer
    /// applies this to every paragraph (EPUB CSS alignment included)
    /// so the setting wins over the book's own declaration.
    @Published var readerTextAlignment: ReaderTextAlignment = .justified {
        didSet { defaults.set(readerTextAlignment.rawValue, forKey: "readerTextAlignment") }
    }

    @Published var readerLayout: ReaderLayout = .paginated {
        didSet {
            guard !loadingPersistedValues else { return }
            defaults.set(readerLayout.rawValue, forKey: "readerLayout")
            defaults.set(true, forKey: "readerLayout.userSet.v1")
        }
    }

    /// Number of text columns shown by the desktop reader in paginated mode.
    @Published var readerColumns: Int = 1 {
        didSet {
            let clamped = max(1, min(4, readerColumns))
            if clamped != readerColumns {
                readerColumns = clamped
                return
            }
            defaults.set(readerColumns, forKey: "readerColumns")
        }
    }

    /// Page-turn animation in paginated mode. Default: `.flip` (curl).
    @Published var pageTurnStyle: PageTurnStyle = .flip {
        didSet { defaults.set(pageTurnStyle.rawValue, forKey: "pageTurnStyle") }
    }

    /// Line spacing in points. 0 = system default (~1.2 line-height).
    /// Range exposed to the UI: 0…16.
    @Published var readerLineSpacing: Double = 6 {
        didSet {
            let clamped = max(0, min(16, readerLineSpacing))
            if clamped != readerLineSpacing {
                readerLineSpacing = clamped
                return
            }
            defaults.set(readerLineSpacing, forKey: "readerLineSpacing")
        }
    }

    /// Horizontal text margin inside the reading column (px).
    ///
    /// The safe-area boundary remains outside this value; an 8pt reader
    /// gutter is therefore safe on compact iPhones while honouring the
    /// user's narrowest selectable margin.
    @Published var readerMargin: Double = 24 {
        didSet {
            let clamped = ReaderLayoutMetrics.clampedMargin(readerMargin)
            if clamped != readerMargin {
                readerMargin = clamped
                return
            }
            defaults.set(readerMargin, forKey: "readerMargin")
        }
    }

    /// Maximum reading column width. Controls how wide a line gets on
    /// large windows; iPad/Mac users typically want narrower columns.
    @Published var readerColumnWidth: Double = 720 {
        didSet {
            let clamped = max(420, min(960, readerColumnWidth))
            if clamped != readerColumnWidth {
                readerColumnWidth = clamped
                return
            }
            defaults.set(readerColumnWidth, forKey: "readerColumnWidth")
        }
    }

    /// Custom theme — packed RGB values stored as comma-separated
    /// "r,g,b,r,g,b" (background then foreground). Doubles 0…1.
    /// Stored as a string for back-compat with the old @AppStorage
    /// key; surfaced via the typed `readerCustomColors` computed
    /// property below.
    @Published private var storedReaderCustomColors: String = "1,1,1,0,0,0" {
        didSet { defaults.set(storedReaderCustomColors, forKey: "readerCustomColors") }
    }

    /// Decoded (background, foreground) RGB tuple — six doubles in
    /// 0…1, defaults to white-on-black if the stored string is bad.
    /// Backed by `storedReaderCustomColors`, which is the observed
    /// stored property — assignment here flows through and triggers
    /// the observation update.
    var readerCustomColors: (background: (Double, Double, Double),
                              foreground: (Double, Double, Double)) {
        get {
            let parts = storedReaderCustomColors
                .split(separator: ",")
                .compactMap { Double($0) }
            guard parts.count == 6 else {
                return ((1, 1, 1), (0, 0, 0))
            }
            return ((parts[0], parts[1], parts[2]),
                    (parts[3], parts[4], parts[5]))
        }
        set {
            let v = [newValue.background.0, newValue.background.1, newValue.background.2,
                     newValue.foreground.0, newValue.foreground.1, newValue.foreground.2]
            storedReaderCustomColors = v.map { String(format: "%.4f", $0) }.joined(separator: ",")
        }
    }

    /// Compatibility shim for legacy screens. Apple production never uses a
    /// remote backend, so this intentionally always returns nil.
    var resolvedBaseURL: URL? {
        nil
    }

    // MARK: Override knobs (opt-in)
    //
    // Every override defaults to **off** — fresh installs see the
    // EPUB exactly as the author intended (rendered from raw HTML/CSS
    // by `EpubHtmlRenderer`). When the user flips one on in the
    // reader toolbar, the corresponding default (e.g. `readerFontFamily`
    // or `readerTheme`) takes priority over the EPUB's own styling.
    // `restoreOriginal()` resets every override-related field below.

    /// When `true`, every text run is re-rendered in `readerFontFamily`,
    /// overriding the font baked into the EPUB's CSS / inline styles.
    @Published var readerOverrideFontFamily: Bool = false {
        didSet { defaults.set(readerOverrideFontFamily, forKey: "readerOverrideFontFamily") }
    }

    /// When `true`, every text run is forced to `readerPointSize`,
    /// overriding the EPUB's font-size CSS.
    @Published var readerOverrideFontSize: Bool = false {
        didSet { defaults.set(readerOverrideFontSize, forKey: "readerOverrideFontSize") }
    }

    /// When `true`, the reader theme (or custom RGB) wins over any
    /// inline `color:` / `background-color:` declared by the EPUB.
    @Published var readerOverrideColours: Bool = false {
        didSet { defaults.set(readerOverrideColours, forKey: "readerOverrideColours") }
    }

    /// When `true`, every run is rendered with `.bold` weight. Useful
    /// for low-vision users; toggling it on does NOT modify the EPUB's
    /// own bold-tag detection — it stacks on top.
    @Published var readerBoldOverride: Bool = false {
        didSet { defaults.set(readerBoldOverride, forKey: "readerBoldOverride") }
    }

    /// When `true`, italic slant is stripped from every run. The
    /// EPUB's own `<i>`/`<em>` markers are honoured by the renderer
    /// (we still parse them), but the final attributed string flattens
    /// the slant trait.
    @Published var readerSuppressItalic: Bool = false {
        didSet { defaults.set(readerSuppressItalic, forKey: "readerSuppressItalic") }
    }

    /// Additional kerning per character glyph, in points. Range
    /// surfaced in the UI: -2.0…4.0 step 0.25. Zero = no change.
    @Published var readerLetterSpacing: Double = 0 {
        didSet {
            let clamped = max(-2, min(4, readerLetterSpacing))
            if clamped != readerLetterSpacing {
                readerLetterSpacing = clamped
                return
            }
            defaults.set(readerLetterSpacing, forKey: "readerLetterSpacing")
        }
    }

    /// Additional space added after each whitespace character, in
    /// points. Range 0…8. Implemented as paragraph-style `wordSpacing`
    /// on the resulting NSAttributedString (NSKern on space glyphs).
    @Published var readerWordSpacing: Double = 0 {
        didSet {
            let clamped = max(0, min(8, readerWordSpacing))
            if clamped != readerWordSpacing {
                readerWordSpacing = clamped
                return
            }
            defaults.set(readerWordSpacing, forKey: "readerWordSpacing")
        }
    }

    /// One-tap "show me the book exactly as the author intended".
    /// Clears every override-related field added above. Preserves
    /// preferences that aren't tied to an override (e.g. layout,
    /// auto-scroll, line-spacing/margin/column-width — those still
    /// affect the surrounding chrome even when no override is on).
    ///
    /// Reset set (mirrors the brief):
    ///   - readerOverrideFontFamily → false
    ///   - readerOverrideFontSize → false
    ///   - readerOverrideColours → false
    ///   - readerBoldOverride → false
    ///   - readerSuppressItalic → false
    ///   - readerLetterSpacing → 0
    ///   - readerWordSpacing → 0
    ///
    /// Theme is NOT reset — it is a standalone preference (like layout
    /// and backend URL). `restoreOriginal()` only clears the typography
    /// *override* fields. Note: the renderer force-overrides EPUB
    /// colours for every theme except `.light`, so the EPUB's own CSS
    /// colours only survive `restoreOriginal()` when the active theme
    /// is `.light`. `readerFontFamily` / `readerFontSize` values stay —
    /// only their override flags flip off, so the next render falls
    /// back to EPUB-native styling.
    func restoreOriginal() {
        readerOverrideFontFamily = false
        readerOverrideFontSize = false
        readerOverrideColours = false
        readerBoldOverride = false
        readerSuppressItalic = false
        readerLetterSpacing = 0
        readerWordSpacing = 0
    }

    // MARK: Offline cache budget

    /// Maximum on-device audiobook cache size in bytes.
    /// Default: 2 GB. UI should present this in human-readable units.
    @Published var offlineCacheBudgetBytes: Int64 = defaultOfflineCacheBudgetBytes {
        didSet { defaults.set(offlineCacheBudgetBytes, forKey: "offlineCacheBudgetBytes") }
    }

    /// Maximum age (seconds) before a cached audiobook is evicted.
    /// Default: 86 400 s (24 h).
    @Published var offlineCacheTTLSeconds: Double = defaultOfflineCacheTTLSeconds {
        didSet { defaults.set(offlineCacheTTLSeconds, forKey: "offlineCacheTTLSeconds") }
    }

    // MARK: Reading position persistence

    func savedChapterIndex(for bookId: String) -> Int {
        defaults.integer(forKey: "readPos_ch_\(bookId)")
    }

    func saveChapterIndex(_ index: Int, for bookId: String) {
        defaults.set(index, forKey: "readPos_ch_\(bookId)")
    }

    func savedPageIndex(for bookId: String) -> Int {
        defaults.integer(forKey: "readPos_pg_\(bookId)")
    }

    func savePageIndex(_ index: Int, for bookId: String) {
        defaults.set(index, forKey: "readPos_pg_\(bookId)")
    }

    /// Resolved point size for the current font-size step.
    var readerPointSize: CGFloat { Self.pointSize(for: readerFontSize) }

    /// Point size for an arbitrary font-size step (0...4), independent of
    /// the currently selected one — used by size pickers that need to
    /// preview every step's resolved size (e.g. the native reader settings screen).
    static func pointSize(for step: Int) -> CGFloat {
        switch step {
        case 0: return 14
        case 1: return 17
        case 2: return 20
        case 3: return 24
        case 4: return 28
        default: return 20
        }
    }
}
