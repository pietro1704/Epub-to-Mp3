import Foundation
import Combine
import os.log

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
}

enum ReaderColorScheme: Equatable {
    case light
    case dark
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
/// user can flip between localhost (dev), a tunnelled HF Spaces deploy, or
/// any reachable server hosting the Python backend.
///
/// Why direct UserDefaults instead of @AppStorage:
/// `@AppStorage` is a `DynamicProperty` tied to a declarative view tree.
/// Storing preferences directly keeps native controllers and Combine
/// observers on the same persistence channel.
/// Plain `@Published` stored properties + `didSet { UserDefaults... }`
/// gives both Combine publishing and persistence on the same channel.
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Load persisted values. `??` falls back to the @Published
        // initial-value defaults if the key was never set.
        // Default backend URL is empty on iOS device (no localhost server
        // exists in the iPhone sandbox; resolving `localhost:8000` floods
        // the system log with `Connection refused`). The embedded Python
        // runtime handles everything in-process; users only set this in
        // Settings if they actually want to point at a remote backend.
        // macOS keeps the historical localhost value for remote-only tools.
        #if os(macOS)
        self.backendURL = defaults.string(forKey: "backendURL") ?? "http://localhost:8000"
        #else
        self.backendURL = defaults.string(forKey: "backendURL") ?? ""
        #endif
        // The Apple clients use the bundled Python runtime in-process.
        self.useEmbeddedRuntime = defaults.object(forKey: "useEmbeddedRuntime") as? Bool ?? true
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
        self.readerLayout = ReaderLayout(
            rawValue: defaults.string(forKey: "readerLayout") ?? ""
        ) ?? .paginated
        self.readerColumns = max(1, min(4, (defaults.object(forKey: "readerColumns") as? Int) ?? 1))
        // UI tests can pin the reader layout regardless of persisted state,
        // e.g. `-uiTestReaderLayout paginated` / `-uiTestReaderLayout scrolling`.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-uiTestReaderLayout"), i + 1 < args.count,
           let forced = ReaderLayout(rawValue: args[i + 1]) {
            self.readerLayout = forced
        }
        self.pageTurnStyle = PageTurnStyle(
            rawValue: defaults.string(forKey: "pageTurnStyle") ?? ""
        ) ?? .flip
        self.readerLineSpacing = (defaults.object(forKey: "readerLineSpacing") as? Double) ?? 6
        // Coerce stale persisted values from older builds (clamp was 8pt
        // pre-2026-05-12, now 16pt to match Apple HIG portrait minimum).
        // Default 16pt (was 24pt) — maximises text silhouette per user
        // request. Floor lowered to 12pt to match `effectiveReaderMargin`.
        let persistedMargin = (defaults.object(forKey: "readerMargin") as? Double) ?? 16
        self.readerMargin = max(12, min(80, persistedMargin))
        self.readerColumnWidth = (defaults.object(forKey: "readerColumnWidth") as? Double) ?? 720
        self.storedReaderCustomColors =
            defaults.string(forKey: "readerCustomColors") ?? "1,1,1,0,0,0"
        self.readerOverrideFontFamily =
            defaults.object(forKey: "readerOverrideFontFamily") as? Bool ?? false
        self.readerOverrideFontSize =
            defaults.object(forKey: "readerOverrideFontSize") as? Bool ?? false
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
    /// PythonBridge), TTS conversion (PythonEmbed on iOS and macOS) —
    /// and treats the configured `backendURL` only as an
    /// optional remote fallback for users who genuinely want it.
    ///
    /// Reader paths NEVER require this to be false. EPUB parsing is
    /// local (`EpubMetadataReader` + `ZipReader` + `PythonBridge.parseEpub`).
    /// The flag exists so QA / power users can force the legacy
    /// "remote-only" mode from the debug toggle in Settings.
    @Published var useEmbeddedRuntime: Bool = true {
        didSet { defaults.set(useEmbeddedRuntime, forKey: "useEmbeddedRuntime") }
    }

    /// True iff the reader and library can render the current book
    /// without a configured backend URL. The reader pipeline is always
    /// local on iOS and macOS through PythonBridge, so this is `true` whenever the
    /// embedded runtime is enabled — regardless of `backendURL`.
    var canReadOffline: Bool { useEmbeddedRuntime }

    /// Dimmed while the embedded runtime handles reading/conversion
    /// locally — a remote backend URL has nothing to do in that mode.
    /// Only enabled once the user opts out of the embedded runtime
    /// (`useEmbeddedRuntime = false`), which is when the app actually
    /// talks to a configured backend.
    var remoteBackendControlsEnabled: Bool { !useEmbeddedRuntime }

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
        didSet { defaults.set(readerLayout.rawValue, forKey: "readerLayout") }
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
    /// Lower bound clamped to **16pt** to match Apple HIG (Books app uses
    /// 16pt minimum on iPhone portrait). Values below this caused the
    /// first/last glyphs to clip into the screen edge in portrait — bug
    /// reported 2026-05-12 when the slider allowed 8-12pt and rendered
    /// text outside the safe content area. The minimum is enforced at
    /// the model layer; the consuming Views ALSO guard with
    /// `max(16, settings.readerMargin)` so stale persisted values from
    /// older builds get coerced on first render.
    @Published var readerMargin: Double = 24 {
        didSet {
            let clamped = max(16, min(80, readerMargin))
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

    /// Best-effort parsed URL — returns nil if the user typed garbage so the
    /// caller can surface a validation error instead of silently failing.
    /// The URL is retained only for explicit remote-backend screens.
    var resolvedBaseURL: URL? {
        let trimmed = backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var raw = trimmed
        while raw.hasSuffix("/") { raw.removeLast() }
        if raw.hasSuffix("/api") { raw.removeLast(4) }
        while raw.hasSuffix("/") { raw.removeLast() }
        guard let url = URL(string: raw) else { return nil }
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "EpubToMp3",
                                category: "security")
            logger.warning("resolvedBaseURL: rejected URL with invalid or missing scheme — \"\(raw, privacy: .public)\"")
            return nil
        }
        return url
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
