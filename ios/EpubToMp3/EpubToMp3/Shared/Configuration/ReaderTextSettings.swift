import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Immutable reader typography and palette read from `AppSettings` at one
/// moment. Renderers and theme appliers take this value instead of the whole
/// mutable settings object; the iOS reader also compares two of them to decide
/// whether a settings change needs a re-render or a re-pagination.
struct ReaderTextSettings: Equatable {
    let fontSize: Int
    let fontFamily: ReaderFontFamily
    let theme: ReaderTheme
    let lineSpacing: Double
    let alignment: ReaderTextAlignment
    let overridesFontFamily: Bool
    let overridesFontSize: Bool
    let overridesColours: Bool
    let overridesAlignment: Bool
    let overridesLineSpacing: Bool
    let boldOverride: Bool
    let suppressesItalic: Bool
    let letterSpacing: Double
    let wordSpacing: Double
    /// Background RGB then foreground RGB, as stored by `ReaderCustomColorCodec`.
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
        overridesAlignment = settings.readerOverrideTextAlignment
        overridesLineSpacing = settings.readerOverrideLineSpacing
        boldOverride = settings.readerBoldOverride
        suppressesItalic = settings.readerSuppressItalic
        letterSpacing = settings.readerLetterSpacing
        wordSpacing = settings.readerWordSpacing
        let colors = settings.readerCustomColors
        customColors = [colors.background.0, colors.background.1, colors.background.2,
                        colors.foreground.0, colors.foreground.1, colors.foreground.2]
    }

    var pointSize: CGFloat { ReaderFontScale.pointSize(for: fontSize) }

    var colors: (background: PlatformColor, foreground: PlatformColor, link: PlatformColor) {
        theme.readerColors(customColors: customColorChannels)
    }

    var preferredColorScheme: ReaderColorScheme? {
        theme.readerPreferredColorScheme(customColors: customColorChannels)
    }

    func hasSameGeometry(as other: Self) -> Bool {
        fontSize == other.fontSize && fontFamily == other.fontFamily
            && lineSpacing == other.lineSpacing && alignment == other.alignment
            && overridesFontFamily == other.overridesFontFamily
            && overridesFontSize == other.overridesFontSize
            && overridesAlignment == other.overridesAlignment && overridesLineSpacing == other.overridesLineSpacing
            && boldOverride == other.boldOverride && suppressesItalic == other.suppressesItalic
            && letterSpacing == other.letterSpacing && wordSpacing == other.wordSpacing
    }

    private var customColorChannels: ReaderCustomColorCodec.Colors {
        ((customColors[0], customColors[1], customColors[2]),
         (customColors[3], customColors[4], customColors[5]))
    }
}
