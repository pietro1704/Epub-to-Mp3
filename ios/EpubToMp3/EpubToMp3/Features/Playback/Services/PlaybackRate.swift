import Foundation

/// Playback rates accepted internally, including legacy values.
enum PlaybackRate: Float, CaseIterable, Identifiable {
    case x075 = 0.75
    case x125 = 1.25
    case x175 = 1.75
    case x080 = 0.8
    case x100 = 1.0
    case x130 = 1.3
    case x150 = 1.5
    case x180 = 1.8
    case x300 = 3.0
    case x050 = 0.5
    case x060 = 0.6
    case x070 = 0.7
    case x200 = 2.0
    case x220 = 2.2
    case x250 = 2.5
    case x350 = 3.5
    case x400 = 4.0

    var id: Float { rawValue }

    /// Short label shown inline on the rate button (e.g. "1x", "1.25x").
    var shortLabel: String {
        switch self {
        case .x075: return "0.75x"
        case .x125: return "1.25x"
        case .x175: return "1.75x"
        case .x080: return "0.8x"
        case .x100: return "1x"
        case .x130: return "1.3x"
        case .x150: return "1.5x"
        case .x180: return "1.8x"
        case .x300: return "3x"
        case .x050: return "0.5x"
        case .x060: return "0.6x"
        case .x070: return "0.7x"
        case .x200: return "2x"
        case .x220: return "2.2x"
        case .x250: return "2.5x"
        case .x350: return "3.5x"
        case .x400: return "4x"
        }
    }

    /// Longer label used in segmented pickers / accessibility.
    var label: String { shortLabel }

    /// The ordered options shared by native menus and rate cycling.
    static let primaryRates: [PlaybackRate] = [
        .x075, .x125, .x150, .x175, .x250, .x300
    ]
}
