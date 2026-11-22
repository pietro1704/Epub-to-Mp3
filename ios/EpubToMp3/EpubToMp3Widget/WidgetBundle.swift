import WidgetKit
import SwiftUI

@main
struct EpubToMp3WidgetBundle: WidgetBundle {
    var body: some Widget {
        EpubToMp3Widget()                   // Keep existing home-screen widgets alive.
        NowPlayingWidget()
        LibraryWidget()
        if #available(iOS 16.1, *) {
            NowPlayingLockScreenWidget()    // iOS 16+ lock-screen (.accessoryCircular/Rectangular/Inline)
        }
        if #available(iOS 16.2, *) {
            ConversionLiveActivityWidget()  // iOS 16.2+ Live Activity for conversion progress
        }
    }
}
