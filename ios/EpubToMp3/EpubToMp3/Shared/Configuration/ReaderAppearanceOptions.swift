import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

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

extension ReaderTheme {
    /// The reader page and attributed content share one palette. Explicit
    /// light/dark themes resolve Apple's semantic colors in that appearance;
    /// Auto keeps adaptive colors so it follows the host appearance.
    func readerColors(
        customColors custom: ReaderCustomColorCodec.Colors
    ) -> (background: PlatformColor, foreground: PlatformColor, link: PlatformColor) {
        let base: (background: PlatformColor, foreground: PlatformColor)
        if self == .custom {
            base = (
                PlatformColor(red: CGFloat(custom.background.0), green: CGFloat(custom.background.1), blue: CGFloat(custom.background.2), alpha: 1),
                PlatformColor(red: CGFloat(custom.foreground.0), green: CGFloat(custom.foreground.1), blue: CGFloat(custom.foreground.2), alpha: 1)
            )
        } else {
            #if canImport(UIKit)
            base = previewColors
            #else
            base = macOSColors
            #endif
        }
        let scheme = readerPreferredColorScheme(customColors: custom)
        #if canImport(UIKit)
        var link: UIColor
        if let scheme {
            link = UIColor.link.resolvedColor(with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light))
        } else {
            // Auto follows the host: adjust per resolution so Increase Contrast and Dark keep the link at AA too.
            let background = base.background
            link = UIColor { traits in
                let native = UIColor.link.resolvedColor(with: traits)
                return Self.accessibleLink(native, on: background.resolvedColor(with: traits))
            }
        }
        #else
        var link = NSColor.linkColor
        if let scheme {
            NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                link = NSColor(cgColor: NSColor.linkColor.cgColor) ?? .linkColor
            }
        }
        #endif
        // CONTRAST-AUDIT: a fixed-scheme reader draws links on its own background; the system link blue is only
        // 3.7-4.3:1 on sepia/parchment and lower on custom backgrounds, so darken or lighten it to WCAG AA.
        if scheme != nil { link = Self.accessibleLink(link, on: base.background) }
        return (base.background, base.foreground, link)
    }

    private static func accessibleLink(_ link: PlatformColor, on background: PlatformColor) -> PlatformColor {
        guard let linkRGB = link.srgbComponents, let backgroundRGB = background.srgbComponents else { return link }
        let adjusted = WCAGContrast.adjusted(linkRGB, against: backgroundRGB, minimum: 4.5)
        if adjusted == linkRGB { return link }
        return PlatformColor(red: CGFloat(adjusted.r), green: CGFloat(adjusted.g), blue: CGFloat(adjusted.b), alpha: 1)
    }

    func readerPreferredColorScheme(customColors custom: ReaderCustomColorCodec.Colors) -> ReaderColorScheme? {
        guard self == .custom else { return preferredColorScheme }
        let rgb = custom.background
        func linear(_ value: Double) -> Double {
            let channel = min(1, max(0, value))
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
        return luminance < 0.179 ? .dark : .light
    }
}

extension AppSettings {
    var readerColors: (background: PlatformColor, foreground: PlatformColor, link: PlatformColor) {
        readerTheme.readerColors(customColors: readerCustomColors)
    }

    var readerPreferredColorScheme: ReaderColorScheme? {
        readerTheme.readerPreferredColorScheme(customColors: readerCustomColors)
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

    /// AppKit has no page curl, so the Mac offers Slide and None and reads a stored Flip as Slide.
    static let macCases: [PageTurnStyle] = [.slide, .none]
    var onMac: PageTurnStyle { self == .flip ? .slide : self }
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
