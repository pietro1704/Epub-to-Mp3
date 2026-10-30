import Foundation

/// Audio time and reader text position are separate coordinate spaces.
enum PlaybackNavigationTarget: Equatable {
    case chapterTime(TimeInterval)
    case readerPage(Double)
    case approximateTime(Double)
}
