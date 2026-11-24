import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Persisted preferences for the native reader and embedded Rust conversion.
///
/// Why direct UserDefaults instead of @AppStorage:
/// `@AppStorage` is a `DynamicProperty` tied to a declarative view tree.
/// Storing preferences directly keeps native controllers and Combine
/// observers on the same persistence channel.
/// Plain `@Published` stored properties + `didSet { UserDefaults... }`
/// gives both Combine publishing and persistence on the same channel.
/// The speech preferences are the exception: they live in `SpeechPreferences`
/// (with their own `@Published` properties) and `AppSettings` forwards them
/// and republishes their changes through its `objectWillChange`.
final class AppSettings: ObservableObject {
    static let playbackForwardSecondsKey = "playbackForwardSeconds"
    static let playbackBackwardSecondsKey = "playbackBackwardSeconds"
    static let playbackSkipIntervals: Set<Double> = [15, 30, 45, 60]
    private let defaults: UserDefaults
    private var loadingPersistedValues = true
    /// Narration choices and their rules; `AppSettings` forwards its speech
    /// surface to it (`AppSpeechPreferences.swift`) and republishes its changes.
    let speechPreferences: SpeechPreferences
    private var speechPreferencesObservation: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.readerDefaults = defaults
        self.speechPreferences = SpeechPreferences(defaults: defaults)
        self.playbackForwardSeconds = Self.validPlaybackSkipInterval(
            defaults.object(forKey: Self.playbackForwardSecondsKey) as? Double
        )
        self.playbackBackwardSeconds = Self.validPlaybackSkipInterval(
            defaults.object(forKey: Self.playbackBackwardSecondsKey) as? Double
        )
        reloadReaderPreferences(from: defaults, arguments: ProcessInfo.processInfo.arguments)
        loadingPersistedValues = false
        // Synchronous, like the `@Published` speech properties it replaces:
        // observers still hear about a change before the value moves.
        speechPreferencesObservation = speechPreferences.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }


    // MARK: per-book reading preferences

    /// Where reader appearance preferences are written: the app defaults, or a book's own suite while a book that has
    /// its own preferences is open (`BookReadingPreferencesStore`). Other settings always use `defaults`.
    private var readerDefaults: UserDefaults
    private var bookScopeID: String?

    /// True while the open book uses its own reading preferences instead of the default.
    private(set) var isBookSpecific = false

    private func reloadReaderPreferences(from source: UserDefaults, arguments: [String] = []) {
        let wasLoading = loadingPersistedValues
        loadingPersistedValues = true
        defer { loadingPersistedValues = wasLoading }
        let reader = ReaderLayoutPreferences(defaults: source, arguments: arguments)
        self.readerFontSize = reader.readerFontSize
        self.readerFontFamily = reader.readerFontFamily
        self.readerTheme = reader.readerTheme
        self.readerAutoScroll = reader.readerAutoScroll
        self.readerAudioTrackingEnabled = reader.readerAudioTrackingEnabled
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
        let paragraphs = ReaderParagraphPreferences(defaults: source)
        self.readerOverrideTextAlignment = paragraphs.overridesAlignment
        self.readerOverrideLineSpacing = paragraphs.overridesLineSpacing
        self.readerBoldOverride = reader.readerBoldOverride
        self.readerSuppressItalic = reader.readerSuppressItalic
        self.readerLetterSpacing = reader.readerLetterSpacing
        self.readerWordSpacing = reader.readerWordSpacing
    }

    /// A book opens: its own preferences apply when it has them, else the default.
    func enterBookScope(_ bookID: String, store: BookReadingPreferencesStore = .shared) {
        bookScopeID = bookID
        if let suite = store.suite(for: bookID) {
            readerDefaults = suite
            isBookSpecific = true
        } else {
            readerDefaults = defaults
            isBookSpecific = false
        }
        reloadReaderPreferences(from: readerDefaults)
        objectWillChange.send()
    }

    /// The book closes: the default applies again.
    func leaveBookScope() {
        bookScopeID = nil
        readerDefaults = defaults
        isBookSpecific = false
        reloadReaderPreferences(from: defaults)
        objectWillChange.send()
    }

    /// "Only for this book": the book starts from the current default and keeps its own values from now on.
    func useOnlyForThisBook(store: BookReadingPreferencesStore = .shared) {
        guard let bookID = bookScopeID, !isBookSpecific else { return }
        readerDefaults = store.create(for: bookID, copying: defaults)
        isBookSpecific = true
        objectWillChange.send()
    }

    /// "Use default": the book forgets its own values and follows the default.
    func useDefaultForThisBook(store: BookReadingPreferencesStore = .shared) {
        guard let bookID = bookScopeID, isBookSpecific else { return }
        store.remove(bookID)
        readerDefaults = defaults
        isBookSpecific = false
        reloadReaderPreferences(from: defaults)
        objectWillChange.send()
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

    /// 5-step font size scale: 0=XS, 1=S, 2=M (default), 3=L, 4=XL.
    /// Clamped in `didSet` so the rest of the app can trust 0…4.
    @Published var readerFontSize: Int = 3 {
        didSet {
            let clamped = max(0, min(4, readerFontSize))
            if clamped != readerFontSize {
                readerFontSize = clamped
                return  // recursive set will write defaults
            }
            readerDefaults.set(readerFontSize, forKey: "readerFontSize")
        }
    }

    @Published var readerFontFamily: ReaderFontFamily = .serif {
        didSet {
            readerDefaults.set(readerFontFamily.rawValue, forKey: "readerFontFamily")
            if !loadingPersistedValues { readerOverrideFontFamily = readerFontFamily != .original }
        }
    }

    var selectedReaderFontFamily: ReaderFontFamily { readerOverrideFontFamily ? readerFontFamily : .original }

    @Published var readerTheme: ReaderTheme = .light {
        didSet { readerDefaults.set(readerTheme.rawValue, forKey: "readerTheme") }
    }

    @Published var readerAutoScroll: Bool = true {
        didSet { readerDefaults.set(readerAutoScroll, forKey: "readerAutoScroll") }
    }

    @Published var readerAudioTrackingEnabled: Bool = true {
        didSet { readerDefaults.set(readerAudioTrackingEnabled, forKey: "readerAudioTrackingEnabled") }
    }

    /// Whether the "n / total" page indicator renders at the bottom of
    /// each paginated page. Toggle exposed in `ReaderSettingsSheet`.
    /// When false the indicator is hidden AND the paginator's body
    /// budget reclaims the footer's reserved height so the chapter
    /// uses the freed space.
    @Published var readerShowPageNumbers: Bool = true {
        didSet { readerDefaults.set(readerShowPageNumbers, forKey: "readerShowPageNumbers") }
    }

    /// Changing the control explicitly overrides publisher body alignment.
    @Published var readerTextAlignment: ReaderTextAlignment = .justified {
        didSet {
            guard !loadingPersistedValues else { return }
            readerDefaults.set(readerTextAlignment.rawValue, forKey: "readerTextAlignment")
            readerOverrideTextAlignment = true
        }
    }

    @Published var readerLayout: ReaderLayout = .paginated {
        didSet {
            guard !loadingPersistedValues else { return }
            readerDefaults.set(readerLayout.rawValue, forKey: "readerLayout")
            readerDefaults.set(true, forKey: "readerLayout.userSet.v1")
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
            readerDefaults.set(readerColumns, forKey: "readerColumns")
        }
    }

    /// Page-turn animation in paginated mode. Default: `.flip` (curl).
    @Published var pageTurnStyle: PageTurnStyle = .flip {
        didSet { readerDefaults.set(pageTurnStyle.rawValue, forKey: "pageTurnStyle") }
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
            // Loading must not persist the default: a stored `readerLineSpacing`
            // is the legacy signal of an explicit choice (ReaderParagraphPreferences).
            guard !loadingPersistedValues else { return }
            readerDefaults.set(readerLineSpacing, forKey: "readerLineSpacing")
            readerOverrideLineSpacing = true
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
            readerDefaults.set(readerMargin, forKey: "readerMargin")
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
            readerDefaults.set(readerColumnWidth, forKey: "readerColumnWidth")
        }
    }

    /// Custom theme — packed RGB values stored as comma-separated
    /// "r,g,b,r,g,b" (background then foreground). Doubles 0…1.
    /// Stored as a string for back-compat with the old @AppStorage
    /// key; surfaced via the typed `readerCustomColors` computed
    /// property below.
    @Published private var storedReaderCustomColors: String = "1,1,1,0,0,0" {
        didSet { readerDefaults.set(storedReaderCustomColors, forKey: "readerCustomColors") }
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
        didSet { readerDefaults.set(readerOverrideFontFamily, forKey: "readerOverrideFontFamily") }
    }

    /// When `true`, every text run is forced to `readerPointSize`,
    /// overriding the EPUB's font-size CSS.
    @Published var readerOverrideFontSize: Bool = false {
        didSet { readerDefaults.set(readerOverrideFontSize, forKey: "readerOverrideFontSize") }
    }

    /// When `true`, the reader theme (or custom RGB) wins over any
    /// inline `color:` / `background-color:` declared by the EPUB.
    @Published var readerOverrideColours: Bool = false {
        didSet { readerDefaults.set(readerOverrideColours, forKey: "readerOverrideColours") }
    }

    @Published var readerOverrideTextAlignment: Bool = false {
        didSet { readerDefaults.set(readerOverrideTextAlignment, forKey: "readerOverrideTextAlignment") }
    }

    @Published var readerOverrideLineSpacing: Bool = false {
        didSet { readerDefaults.set(readerOverrideLineSpacing, forKey: "readerOverrideLineSpacing") }
    }

    /// When `true`, every run is rendered with `.bold` weight. Useful
    /// for low-vision users; toggling it on does NOT modify the EPUB's
    /// own bold-tag detection — it stacks on top.
    @Published var readerBoldOverride: Bool = false {
        didSet { readerDefaults.set(readerBoldOverride, forKey: "readerBoldOverride") }
    }

    /// When `true`, italic slant is stripped from every run. The
    /// EPUB's own `<i>`/`<em>` markers are honoured by the renderer
    /// (we still parse them), but the final attributed string flattens
    /// the slant trait.
    @Published var readerSuppressItalic: Bool = false {
        didSet { readerDefaults.set(readerSuppressItalic, forKey: "readerSuppressItalic") }
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
            readerDefaults.set(readerLetterSpacing, forKey: "readerLetterSpacing")
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
            readerDefaults.set(readerWordSpacing, forKey: "readerWordSpacing")
        }
    }

    /// Resolved point size for the current font-size step.
    var readerPointSize: CGFloat { ReaderFontScale.pointSize(for: readerFontSize) }


}
