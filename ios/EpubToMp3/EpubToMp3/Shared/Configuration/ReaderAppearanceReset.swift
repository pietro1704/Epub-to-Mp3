import Foundation

extension AppSettings {
    /// One-tap "show me the book exactly as the author intended".
    /// Clears every override-related field added above. Preserves
    /// preferences that aren't tied to an override (e.g. layout,
    /// auto-scroll, margin and column width). Paragraph controls retain
    /// their values but no longer override the publisher after this reset.
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
    /// Theme is NOT reset — it is a standalone preference (like layout
    /// and backend URL). `restoreOriginal()` only clears the typography
    /// *override* fields. Note: the renderer force-overrides EPUB
    /// colours for every theme except `.light`, so the EPUB's own CSS
    /// colours only survive `restoreOriginal()` when the active theme
    /// is `.light`. `readerFontFamily` / `readerFontSize` values stay —
    /// only their override flags flip off, so the next render falls
    /// back to EPUB-native styling.
    func restoreOriginal() {
        readerOverrideFontFamily = false
        readerOverrideFontSize = false
        readerOverrideColours = false
        readerOverrideTextAlignment = false
        readerOverrideLineSpacing = false
        readerBoldOverride = false
        readerSuppressItalic = false
        readerLetterSpacing = 0
        readerWordSpacing = 0
    }

}
