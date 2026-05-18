import WidgetKit
import SwiftUI

@main
struct EpubToMp3WidgetBundle: WidgetBundle {
    var body: some Widget {
        EpubToMp3Widget()               // legacy kind — keeps existing home-screen widgets alive
        NowPlayingWidget()
        ContinueReadingWidget()
        LibraryWidget()
        NowPlayingLockScreenWidget()    // iOS 16+ lock-screen (.accessoryCircular/Rectangular/Inline)
        ConversionLiveActivityWidget()  // iOS 16.2+ Live Activity for conversion progress
    }
}
