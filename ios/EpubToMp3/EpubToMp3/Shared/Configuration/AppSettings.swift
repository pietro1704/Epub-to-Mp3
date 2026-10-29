import Foundation
import Combine
import os.log
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Persisted preferences for the native reader and embedded Rust conversion.
/// Backend fields retain inert legacy migration values.
///
/// Why direct UserDefaults instead of @AppStorage:
/// `@AppStorage` is a `DynamicProperty` tied to a declarative view tree.
/// Storing preferences directly keeps native controllers and Combine
/// observers on the same persistence channel.
/// Plain `@Published` stored properties + `didSet { UserDefaults... }`
/// gives both Combine publishing and persistence on the same channel.
final class AppSettings: ObservableObject {
    static let audioEngineKey = "audioEngine"
    static let playbackForwardSecondsKey = "playbackForwardSeconds"
    static let playbackBackwardSecondsKey = "playbackBackwardSeconds"
    static let playbackSkipIntervals: Set<Double> = [15, 30, 45, 60]
    private let defaults: UserDefaults
    let readingPosition: ReaderPositionPreferences
    private var loadingPersistedValues = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        readingPosition = ReaderPositionPreferences(defaults: defaults)
        // Conversion is local Rust on every Apple platform. Backend URLs are
        // retained only as inert migration data and never drive production.
        self.backendURL = ""
        self.useEmbeddedRuntime = true
        // Edge is the only network dependency of on-device conversion. Keep
        // it on Wi-Fi by default; the user may opt into cellular explicitly.
        self.allowCellularAudioConversion =
            defaults.object(forKey: "allowCellularAudioConversion") as? Bool ?? false
        let speech = SpeechPreferenceMigration(defaults: defaults)
        self.audioEngine = speech.primary
        if let snapshot = defaults.data(forKey: "primaryTtsSelection") {
            self.primaryTtsSelection = try? JSONDecoder().decode(TtsSelection.self, from: snapshot)
        }
        if let snapshot = defaults.data(forKey: "secondaryTtsSelection") {
            self.secondaryTtsSelection = try? JSONDecoder().decode(TtsSelection.self, from: snapshot)
        }
        self.secondaryAudioEngine = speech.secondary
        self.allowOnlineAudioFallback = speech.allowOnlineFallback
        self.playbackForwardSeconds = Self.validPlaybackSkipInterval(
            defaults.object(forKey: Self.playbackForwardSecondsKey) as? Double
        )
        self.playbackBackwardSeconds = Self.validPlaybackSkipInterval(
            defaults.object(forKey: Self.playbackBackwardSecondsKey) as? Double
        )
        let reader = ReaderLayoutPreferences(defaults: defaults, arguments: ProcessInfo.processInfo.arguments)
        self.readerFontSize = reader.readerFontSize
        self.readerFontFamily = reader.readerFontFamily
        self.readerTheme = reader.readerTheme
        self.readerAutoScroll = reader.readerAutoScroll
        self.readerShowPageNumbers = reader.readerShowPageNumbers
        self.readerTextAlignment = reader.readerTextAlignment
        self.readerLayout = reader.readerLayout
        self.readerColumns = reader.readerColumns
        self.pageTurnStyle = reader.pageTurnStyle
        self.readerLineSpacing = reader.readerLineSpacing
        self.readerMargin = reader.readerMargin
        self.readerColumnWidth = reader.readerColumnWidth
        self.storedReaderCustomColors = reader.storedReaderCustomColors
        self.readerOverrideFontFamily = reader.readerOverrideFontFamily
        self.readerOverrideFontSize = reader.readerOverrideFontSize
        self.readerOverrideColours = reader.readerOverrideColours
        let paragraphs = ReaderParagraphPreferences(defaults: defaults)
        self.readerOverrideTextAlignment = paragraphs.overridesAlignment
        self.readerOverrideLineSpacing = paragraphs.overridesLineSpacing
        self.readerBoldOverride = reader.readerBoldOverride
        self.readerSuppressItalic = reader.readerSuppressItalic
        self.readerLetterSpacing = reader.readerLetterSpacing
        self.readerWordSpacing = reader.readerWordSpacing
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
            primaryTtsSelection = nil
            adoptCurrentSpeechPolicyIfEdited()
            defaults.set(audioEngine.rawValue, forKey: Self.audioEngineKey)
            if secondaryAudioEngine == audioEngine { secondaryAudioEngine = nil }
        }
    }

    @Published var secondaryAudioEngine: AudioEnginePreference? = nil {
        didSet {
            guard !loadingPersistedValues else { return }
            secondaryTtsSelection = nil
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
    @Published var primaryTtsSelection: TtsSelection? = nil {
        didSet {
            guard !loadingPersistedValues else { return }
            defaults.set(try? primaryTtsSelection.map { try JSONEncoder().encode($0) }, forKey: "primaryTtsSelection")
        }
    }
    @Published var secondaryTtsSelection: TtsSelection? = nil {
        didSet {
            guard !loadingPersistedValues else { return }
            defaults.set(try? secondaryTtsSelection.map { try JSONEncoder().encode($0) }, forKey: "secondaryTtsSelection")
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
            if !allowOnlineAudioFallback && secondaryTtsSelection?.engine == "edge" {
                secondaryTtsSelection = nil
            }
        }
    }
    private func adoptCurrentSpeechPolicyIfEdited() {
        guard !loadingPersistedValues else { return }
        defaults.set(2, forKey: "ttsPreferencesVersion")
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

    /// Reader and library access use the local Apple projection without a backend.
    var canReadOffline: Bool { true }

    /// Legacy backend controls stay hidden in the embedded production client.
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

    /// Changing the control explicitly overrides publisher body alignment.
    @Published var readerTextAlignment: ReaderTextAlignment = .justified {
        didSet {
            guard !loadingPersistedValues else { return }
            defaults.set(readerTextAlignment.rawValue, forKey: "readerTextAlignment")
            readerOverrideTextAlignment = true
        }
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
            if !loadingPersistedValues { readerOverrideLineSpacing = true }
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
        get { ReaderCustomColorCodec.decode(storedReaderCustomColors) }
        set { storedReaderCustomColors = ReaderCustomColorCodec.encode(newValue) }
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

    @Published var readerOverrideTextAlignment: Bool = false {
        didSet { defaults.set(readerOverrideTextAlignment, forKey: "readerOverrideTextAlignment") }
    }

    @Published var readerOverrideLineSpacing: Bool = false {
        didSet { defaults.set(readerOverrideLineSpacing, forKey: "readerOverrideLineSpacing") }
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

    /// Resolved point size for the current font-size step.
    var readerPointSize: CGFloat { ReaderFontScale.pointSize(for: readerFontSize) }


}
