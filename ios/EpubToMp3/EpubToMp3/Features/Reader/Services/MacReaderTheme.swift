#if os(macOS) && !targetEnvironment(simulator)
import AppKit

/// Applies the selected reader theme to AppKit's opaque text surface.
/// EPUB HTML may retain its own foreground colour, so the native background
/// must never be inherited from the surrounding application window.
@MainActor
enum MacReaderTheme {
    static func apply(
        settings: AppSettings,
        surface: NSView,
        scrollView: NSScrollView,
        textView: NSTextView,
        toolbar: NSView? = nil,
        labels: [NSTextField] = []
    ) {
        let baseColors: (background: NSColor, foreground: NSColor)
        if settings.readerTheme == .custom {
            let custom = settings.readerCustomColors
            baseColors = (
                NSColor(red: custom.background.0, green: custom.background.1, blue: custom.background.2, alpha: 1),
                NSColor(red: custom.foreground.0, green: custom.foreground.1, blue: custom.foreground.2, alpha: 1)
            )
        } else {
            baseColors = settings.readerTheme.macOSColors
        }
        // `cgColor` resolves a dynamic AppKit colour immediately. Resolve
        // both colours against this reader surface first so `.auto` cannot
        // combine a Dark Aqua background with an Aqua label colour.
        let colors = (
            background: resolved(baseColors.background, for: surface.effectiveAppearance),
            foreground: resolved(baseColors.foreground, for: surface.effectiveAppearance)
        )

        surface.wantsLayer = true
        surface.layer?.backgroundColor = colors.background.cgColor
        toolbar?.wantsLayer = true
        toolbar?.layer?.backgroundColor = colors.background.cgColor
        scrollView.drawsBackground = true
        scrollView.backgroundColor = colors.background
        textView.drawsBackground = true
        textView.backgroundColor = colors.background
        textView.textColor = colors.foreground
        labels.forEach { $0.textColor = colors.foreground }
    }

    private static func resolved(_ color: NSColor, for appearance: NSAppearance) -> NSColor {
        var staticColor = color
        appearance.performAsCurrentDrawingAppearance {
            staticColor = NSColor(cgColor: color.cgColor) ?? color
        }
        return staticColor
    }
}
#endif
