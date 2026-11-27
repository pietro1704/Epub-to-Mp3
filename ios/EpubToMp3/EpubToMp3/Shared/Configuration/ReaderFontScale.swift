import Foundation

enum ReaderFontScale {
    static let maximumStep = PointPresetScale.font.count - 1

    /// Point size for an arbitrary font-size step, independent of
    /// the currently selected one — used by size pickers that need to
    /// preview every step's resolved size (e.g. the native reader settings screen).
    static func pointSize(for step: Int) -> CGFloat {
        PointPresetScale.font.indices.contains(step) ? CGFloat(PointPresetScale.font[step]) : 20
    }
}
