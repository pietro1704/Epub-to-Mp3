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
        let appearanceName: NSAppearance.Name?
        switch settings.readerPreferredColorScheme {
        case .dark: appearanceName = .darkAqua
        case .light: appearanceName = .aqua
        case nil: appearanceName = nil
        }
        if surface.appearance?.name != appearanceName {
            surface.appearance = appearanceName.flatMap { NSAppearance(named: $0) }
        }
        let baseColors = settings.readerColors
        // `cgColor` resolves a dynamic AppKit colour immediately. Resolve
        // both colours against this reader surface first so `.auto` cannot
        // combine a Dark Aqua background with an Aqua label colour.
        let colors = (
            background: resolved(baseColors.background, for: surface.effectiveAppearance),
            foreground: resolved(baseColors.foreground, for: surface.effectiveAppearance),
            link: resolved(baseColors.link, for: surface.effectiveAppearance)
        )

        surface.wantsLayer = true
        surface.layer?.backgroundColor = colors.background.cgColor
        toolbar?.wantsLayer = true
        toolbar?.layer?.backgroundColor = colors.background.cgColor
        scrollView.drawsBackground = true
        scrollView.backgroundColor = colors.background
        textView.drawsBackground = true
        textView.backgroundColor = colors.background
        let overridesColors = settings.readerTheme != .light || settings.readerOverrideColours
        if textView.string.isEmpty {
            textView.textColor = colors.foreground
        } else if overridesColors, let storage = textView.textStorage {
            // Setting NSTextView.textColor replaces every authored foreground.
            // Recolor only override modes, keeping links distinct and saved
            // highlight backgrounds intact during appearance-only refreshes.
            storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length), options: []) { link, range, _ in
                storage.addAttribute(.foregroundColor, value: link == nil ? colors.foreground : colors.link, range: range)
            }
        }
        // In the original light theme, authored link colors remain part of
        // the EPUB; all overriding themes use the native semantic link color.
        textView.linkTextAttributes = overridesColors
            ? [.foregroundColor: colors.link, .underlineStyle: NSUnderlineStyle.single.rawValue]
            : [:]
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
