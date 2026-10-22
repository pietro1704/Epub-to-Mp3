import Foundation

enum ReaderFontScale {
    /// Point size for an arbitrary font-size step (0...4), independent of
    /// the currently selected one — used by size pickers that need to
    /// preview every step's resolved size (e.g. the native reader settings screen).
    static func pointSize(for step: Int) -> CGFloat {
        switch step {
        case 0: return 14
        case 1: return 17
        case 2: return 20
        case 3: return 24
        case 4: return 28
        default: return 20
        }
    }
}
