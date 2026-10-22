import Foundation

/// Initial reader values and explicit UI-test overrides, with persistence left in AppSettings.
struct ReaderLayoutPreferences {
    var readerFontSize: Int = 3
    var readerFontFamily: ReaderFontFamily = .serif
    var readerTheme: ReaderTheme = .light
    var readerAutoScroll: Bool = true
    var readerShowPageNumbers: Bool = true
    var readerTextAlignment: ReaderTextAlignment = .justified
    var readerLayout: ReaderLayout = .paginated
    var readerColumns: Int = 1
    var pageTurnStyle: PageTurnStyle = .flip
    var readerLineSpacing: Double = 6
    var readerMargin: Double = 24
    var readerColumnWidth: Double = 720
    var storedReaderCustomColors: String = "1,1,1,0,0,0"
    var readerOverrideFontFamily: Bool = false
    var readerOverrideFontSize: Bool = false
    var readerOverrideColours: Bool = false
    var readerBoldOverride: Bool = false
    var readerSuppressItalic: Bool = false
    var readerLetterSpacing: Double = 0
    var readerWordSpacing: Double = 0

    init(defaults: UserDefaults, arguments args: [String]) {
        readerFontSize = (defaults.object(forKey: "readerFontSize") as? Int) ?? 3
        readerFontFamily = ReaderFontFamily(
            rawValue: defaults.string(forKey: "readerFontFamily") ?? ""
        ) ?? .serif
        readerTheme = ReaderTheme(
            rawValue: defaults.string(forKey: "readerTheme") ?? ""
        ) ?? .auto
        readerAutoScroll = defaults.object(forKey: "readerAutoScroll") as? Bool ?? true
        readerShowPageNumbers = defaults.object(forKey: "readerShowPageNumbers") as? Bool ?? true
        readerTextAlignment = ReaderTextAlignment(
            rawValue: defaults.string(forKey: "readerTextAlignment") ?? ""
        ) ?? .justified
        // A book opens paginated until the user explicitly chooses another
        // layout. Legacy raw values are not treated as an explicit choice.
        let layoutWasChosen = defaults.bool(forKey: "readerLayout.userSet.v1")
        readerLayout = layoutWasChosen
            ? (ReaderLayout(rawValue: defaults.string(forKey: "readerLayout") ?? "") ?? .paginated)
            : .paginated
        readerColumns = max(1, min(4, (defaults.object(forKey: "readerColumns") as? Int) ?? 1))
        // UI tests can pin the reader layout regardless of persisted state,
        // e.g. `-uiTestReaderLayout paginated` / `-uiTestReaderLayout scrolling`.
        if let i = args.firstIndex(of: "-uiTestReaderFontSize"), i + 1 < args.count,
           let forcedSize = Int(args[i + 1]) {
            readerFontSize = max(0, min(4, forcedSize))
        }
        if let i = args.firstIndex(of: "-uiTestReaderLayout"), i + 1 < args.count,
           let forced = ReaderLayout(rawValue: args[i + 1]) {
            readerLayout = forced
        }
        if args.contains("-uiTestReaderShowPageNumbers") {
            readerShowPageNumbers = true
        }
        pageTurnStyle = PageTurnStyle(
            rawValue: defaults.string(forKey: "pageTurnStyle") ?? ""
        ) ?? .flip
        if let i = args.firstIndex(of: "-uiTestPageTurnStyle"), i + 1 < args.count,
           let forced = PageTurnStyle(rawValue: args[i + 1]) {
            pageTurnStyle = forced
        }
        readerLineSpacing = (defaults.object(forKey: "readerLineSpacing") as? Double) ?? 6
        // The reader keeps an 8pt minimum inside the safe-area content
        // boundary. This leaves a visible gutter without unnecessarily
        // narrowing the reading column on compact iPhones.
        let persistedMargin = (defaults.object(forKey: "readerMargin") as? Double) ?? 16
        readerMargin = ReaderLayoutMetrics.clampedMargin(persistedMargin)
        readerColumnWidth = (defaults.object(forKey: "readerColumnWidth") as? Double) ?? 720
        storedReaderCustomColors =
            defaults.string(forKey: "readerCustomColors") ?? "1,1,1,0,0,0"
        readerOverrideFontFamily =
            defaults.object(forKey: "readerOverrideFontFamily") as? Bool ?? false
        readerOverrideFontSize =
            defaults.object(forKey: "readerOverrideFontSize") as? Bool ?? false
        if args.contains("-uiTestReaderOverrideFontSize") {
            readerOverrideFontSize = true
        }
        readerOverrideColours =
            defaults.object(forKey: "readerOverrideColours") as? Bool ?? false
        readerBoldOverride =
            defaults.object(forKey: "readerBoldOverride") as? Bool ?? false
        readerSuppressItalic =
            defaults.object(forKey: "readerSuppressItalic") as? Bool ?? false
        readerLetterSpacing =
            (defaults.object(forKey: "readerLetterSpacing") as? Double) ?? 0
        readerWordSpacing =
            (defaults.object(forKey: "readerWordSpacing") as? Double) ?? 0
    }
}
