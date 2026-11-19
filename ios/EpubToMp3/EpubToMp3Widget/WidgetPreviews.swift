import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Previews
// ============================================================================

#if os(iOS)
// Now Playing
@available(iOS 17.0, *)
#Preview("Now Playing — small", as: .systemSmall) {
    NowPlayingWidget()
} timeline: {
    NowPlayingEntry.placeholder
}

@available(iOS 17.0, *)
#Preview("Now Playing — medium", as: .systemMedium) {
    NowPlayingWidget()
} timeline: {
    NowPlayingEntry.placeholder
}

@available(iOS 17.0, *)
#Preview("Now Playing — empty", as: .systemSmall) {
    NowPlayingWidget()
} timeline: {
    NowPlayingEntry.empty
}

// Library
@available(iOS 17.0, *)
#Preview("Library — medium", as: .systemMedium) {
    LibraryWidget()
} timeline: {
    LibraryEntry.placeholder
}

@available(iOS 17.0, *)
#Preview("Library — large", as: .systemLarge) {
    LibraryWidget()
} timeline: {
    LibraryEntry.placeholder
}

@available(iOS 17.0, *)
#Preview("Library — empty", as: .systemMedium) {
    LibraryWidget()
} timeline: {
    LibraryEntry.empty
}
#endif
