#if os(iOS)
import UIKit

enum ReaderTapAction: Equatable {
    case toggleChrome
    case turnPage(forward: Bool)
    case none

    static func resolve(point: CGPoint, in bounds: CGRect, isPaginated: Bool) -> ReaderTapAction {
        guard bounds.contains(point) else { return .none }
        // Reader controls use the familiar three vertical zones: a middle
        // column toggles chrome anywhere along the readable page, while the
        // left and right columns turn pages in paginated mode. Depending on
        // y made a tap in the visual middle near the top or bottom turn pages
        // unexpectedly.
        let middleColumn = bounds.insetBy(dx: bounds.width / 3, dy: 0)
        if middleColumn.contains(point) {
            return .toggleChrome
        }
        guard isPaginated else { return .none }
        return .turnPage(forward: point.x >= bounds.midX)
    }
}

enum ReaderLoadingLayoutMetrics {
    static let coverAspectRatio: CGFloat = 1.5
    static let preferredCoverWidthFraction: CGFloat = 0.42
    static let maximumCoverWidthFraction: CGFloat = 0.60
    static let maximumCoverHeightFraction: CGFloat = 0.42
    static let minimumVerticalMargin: CGFloat = 24
    static let preferredTopSpacing: CGFloat = 48
}

struct ReaderViewportConfiguration: Equatable {
    let allowsVerticalScrolling: Bool
    let allowsChapterSwipes: Bool
    let usesPaginatedTextHeight: Bool
    let showsPageIndicator: Bool
    let usesScreenEdges: Bool

    static func resolve(
        layout: ReaderLayout,
        chromeHidden: Bool,
        showsPageNumbers: Bool
    ) -> ReaderViewportConfiguration {
        let paginated = layout == .paginated
        return ReaderViewportConfiguration(
            allowsVerticalScrolling: !paginated,
            allowsChapterSwipes: !paginated,
            usesPaginatedTextHeight: paginated,
            showsPageIndicator: paginated && !chromeHidden && showsPageNumbers,
            // Immersive mode removes reader chrome, not the system safe
            // area. Keeping text inside it prevents content from extending
            // under the status bar or home indicator during a reflow.
            usesScreenEdges: false
        )
    }
}

enum ReaderTextViewFactory {
    /// The reader intentionally uses NSLayoutManager for pagination, glyph
    /// positions, and page-boundary calculations. Build it with TextKit 1 so
    /// those accesses do not force UIKit to switch a TextKit 2 view at runtime.
    static func make() -> UITextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: .zero)
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        return UITextView(frame: .zero, textContainer: textContainer)
    }
}

struct ReaderTextSettings: Equatable {
    let fontSize: Int
    let fontFamily: ReaderFontFamily
    let theme: ReaderTheme
    let lineSpacing: Double
    let alignment: ReaderTextAlignment
    let overridesFontFamily: Bool
    let overridesFontSize: Bool
    let overridesColours: Bool
    let boldOverride: Bool
    let suppressesItalic: Bool
    let letterSpacing: Double
    let wordSpacing: Double
    let customColors: [Double]

    init(settings: AppSettings) {
        fontSize = settings.readerFontSize
        fontFamily = settings.readerFontFamily
        theme = settings.readerTheme
        lineSpacing = settings.readerLineSpacing
        alignment = settings.readerTextAlignment
        overridesFontFamily = settings.readerOverrideFontFamily
        overridesFontSize = settings.readerOverrideFontSize
        overridesColours = settings.readerOverrideColours
        boldOverride = settings.readerBoldOverride
        suppressesItalic = settings.readerSuppressItalic
        letterSpacing = settings.readerLetterSpacing
        wordSpacing = settings.readerWordSpacing
        let colors = settings.readerCustomColors
        customColors = [colors.background.0, colors.background.1, colors.background.2,
                        colors.foreground.0, colors.foreground.1, colors.foreground.2]
    }

    func hasSameGeometry(as other: Self) -> Bool {
        fontSize == other.fontSize && fontFamily == other.fontFamily
            && lineSpacing == other.lineSpacing && alignment == other.alignment
            && overridesFontFamily == other.overridesFontFamily
            && overridesFontSize == other.overridesFontSize
            && boldOverride == other.boldOverride && suppressesItalic == other.suppressesItalic
            && letterSpacing == other.letterSpacing && wordSpacing == other.wordSpacing
    }
}

#endif
