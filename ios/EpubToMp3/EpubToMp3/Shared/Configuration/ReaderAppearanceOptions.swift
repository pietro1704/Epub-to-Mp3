import Foundation
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
