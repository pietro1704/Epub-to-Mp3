#if canImport(AppKit)
import AppKit

@MainActor
struct MacReaderAppearance {
    let foreground: NSColor
    let background: NSColor

    static func resolve(settings: AppSettings) -> Self {
        switch settings.readerTheme {
        case .auto:
            return Self(foreground: .labelColor, background: .textBackgroundColor)
        case .light:
            return Self(foreground: .black, background: .white)
        case .sepia:
            return Self(foreground: rgb(0.20, 0.15, 0.10), background: rgb(0.96, 0.93, 0.85))
        case .parchment:
            return Self(foreground: rgb(0.18, 0.13, 0.06), background: rgb(0.94, 0.89, 0.78))
        case .paper:
            return Self(foreground: rgb(0.10, 0.10, 0.10), background: rgb(0.98, 0.97, 0.94))
        case .dark:
            return Self(foreground: rgb(0.92, 0.92, 0.92), background: rgb(0.12, 0.12, 0.14))
        case .black:
            return Self(foreground: rgb(0.95, 0.95, 0.95), background: .black)
        case .custom:
            let colors = settings.readerCustomColors
            return Self(
                foreground: rgb(colors.foreground.0, colors.foreground.1, colors.foreground.2),
                background: rgb(colors.background.0, colors.background.1, colors.background.2)
            )
        }
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> NSColor {
        NSColor(red: red, green: green, blue: blue, alpha: 1)
    }
}
#endif
