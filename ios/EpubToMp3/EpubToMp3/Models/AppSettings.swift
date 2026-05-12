import Foundation
import SwiftUI

/// Reader appearance choices surfaced in `ReaderView`'s toolbar.
enum ReaderFontFamily: String, CaseIterable, Identifiable {
    case serif
    case sans
    case mono

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .serif: return "Serif"
        case .sans:  return "Sans"
        case .mono:  return "Mono"
        }
    }
}

enum ReaderTheme: String, CaseIterable, Identifiable {
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
        case .light:     return "Light"
        case .sepia:     return "Sepia"
        case .parchment: return "Parchment"
        case .paper:     return "Paper"
        case .dark:      return "Dark"
        case .black:     return "Black"
        case .custom:    return "Custom"
        }
    }

    /// Preferred color scheme to inject via `.preferredColorScheme`.
    ///
    /// Dark and Black themes force `.dark` so all SwiftUI-native controls
    /// (pickers, menus, sheets presented from within the reader) also
    /// render in dark mode — matching the reader background. Warm themes
    /// (Sepia, Parchment, Paper) and Light explicitly force `.light` so
    /// they never accidentally inherit OS dark mode. Custom returns `nil`
    /// (follows system) because we don't know whether the user's custom
    /// colours are a dark or light palette.
    ///
    /// HIG note: this only affects views *below* the modifier in the
    /// hierarchy — the navigation bar, tab bar, and any UI outside the
    /// reader are not affected. This is the exact same scoping Apple
    /// Books uses.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .dark, .black:            return .dark
        case .light, .sepia, .parchment, .paper: return .light
        case .custom:                  return nil
        }
    }
}

enum ReaderLayout: String, CaseIterable, Identifiable {
    case scrolling
    case paginated

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .scrolling: return "Scrolling"
        case .paginated: return "Paginated"
        }
    }
}

/// Persisted user preferences. The backend URL drives every API call so the
/// user can flip between localhost (dev), a tunnelled HF Spaces deploy, or
/// any reachable server hosting the Python backend.
///
/// Why direct UserDefaults instead of @AppStorage:
/// `@AppStorage` is a `DynamicProperty` that only emits change events when
/// the wrapper is read from inside a SwiftUI `View`. Stashing it inside an
/// `ObservableObject` (even via a non-`@Published` stored property) means
/// the surrounding View never gets notified that a stored value changed —
/// so toolbar pickers in `ReaderView` looked like they did nothing.
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
        // macOS keeps the localhost default since the sidecar binds there.
        #if os(macOS)
        self.backendURL = defaults.string(forKey: "backendURL") ?? "http://localhost:8000"
        #else
        self.backendURL = defaults.string(forKey: "backendURL") ?? ""
        #endif
        self.useEmbeddedSidecar = defaults.object(forKey: "useEmbeddedSidecar") as? Bool ?? true
        // Default ON everywhere — iOS uses PythonEmbed (in-process CPython
        // via `Python.xcframework`); macOS uses the PyInstaller sidecar.
        // Both ship inside the app bundle and let the reader work without
        // any external backend URL.
        self.useEmbeddedRuntime = defaults.object(forKey: "useEmbeddedRuntime") as? Bool ?? true
        self.readerFontSize = (defaults.object(forKey: "readerFontSize") as? Int) ?? 2
        self.readerFontFamily = ReaderFontFamily(
            rawValue: defaults.string(forKey: "readerFontFamily") ?? ""
        ) ?? .serif
        self.readerTheme = ReaderTheme(
            rawValue: defaults.string(forKey: "readerTheme") ?? ""
        ) ?? .light
        self.readerAutoScroll = defaults.object(forKey: "readerAutoScroll") as? Bool ?? true
        self.readerLayout = ReaderLayout(
            rawValue: defaults.string(forKey: "readerLayout") ?? ""
        ) ?? .scrolling
        self.readerLineSpacing = (defaults.object(forKey: "readerLineSpacing") as? Double) ?? 6
        self.readerMargin = (defaults.object(forKey: "readerMargin") as? Double) ?? 24
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
    }

    /// Filled in by `SidecarManager` once the bundled Python server is
    /// healthy. When non-nil and `useEmbeddedSidecar == true`, all API
    /// calls go to this URL instead of the user-typed `backendURL`. Not
    /// persisted — the port is recomputed on each app launch.
    @Published var sidecarURL: URL? = nil

    @Published var backendURL: String = "" {
        didSet { defaults.set(backendURL, forKey: "backendURL") }
    }

    /// Whether to prefer the embedded sidecar over the user-configured
    /// backend URL. macOS-only switch (iOS / iPadOS always use
    /// `backendURL` since they cannot embed a Python process).
    @Published var useEmbeddedSidecar: Bool = true {
        didSet { defaults.set(useEmbeddedSidecar, forKey: "useEmbeddedSidecar") }
    }

    /// Master switch: when `true` the app uses its bundled runtime for
    /// everything that *can* run on-device — EPUB parsing (pure Swift +
    /// PythonBridge), TTS conversion (PythonEmbed on iOS, sidecar on
    /// macOS) — and treats the configured `backendURL` only as an
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
    /// local on iOS (PythonBridge / EpubMetadataReader) and macOS uses
    /// the auto-started sidecar, so this is `true` whenever the
    /// embedded runtime is enabled — regardless of `backendURL`.
    var canReadOffline: Bool { useEmbeddedRuntime }

    /// 5-step font size scale: 0=XS, 1=S, 2=M (default), 3=L, 4=XL.
    /// Clamped in `didSet` so the rest of the app can trust 0…4.
    @Published var readerFontSize: Int = 2 {
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

    @Published var readerLayout: ReaderLayout = .scrolling {
        didSet { defaults.set(readerLayout.rawValue, forKey: "readerLayout") }
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
    @Published var readerMargin: Double = 24 {
        didSet {
            let clamped = max(8, min(80, readerMargin))
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
    /// On macOS, when `useEmbeddedSidecar` is on and the sidecar has come
    /// up healthy, the sidecar URL wins so the app stays self-contained
    /// even if the user once pointed `backendURL` at HF Spaces.
    var resolvedBaseURL: URL? {
        if useEmbeddedSidecar, let sidecarURL { return sidecarURL }
        let trimmed = backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed)
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
    /// Theme is NOT reset because the user may want their dark
    /// theme even when "show original" is requested — the override
    /// flag (`readerOverrideColours`) is what gates whether the theme
    /// actually wins over the EPUB. Same for `readerFontFamily` /
    /// `readerFontSize`: the values stay but the overrides flip off,
    /// so the next render falls back to EPUB-native styling.
    func restoreOriginal() {
        readerOverrideFontFamily = false
        readerOverrideFontSize = false
        readerOverrideColours = false
        readerBoldOverride = false
        readerSuppressItalic = false
        readerLetterSpacing = 0
        readerWordSpacing = 0
    }

    /// Resolved point size for the current font-size step.
    var readerPointSize: CGFloat {
        switch readerFontSize {
        case 0: return 14
        case 1: return 17
        case 2: return 20
        case 3: return 24
        case 4: return 28
        default: return 20
        }
    }
}
