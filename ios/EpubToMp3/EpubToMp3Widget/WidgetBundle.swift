import WidgetKit
import SwiftUI

@main
struct EpubToMp3WidgetBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 17.0, *) {
            EpubToMp3Widget()               // legacy kind — keeps existing home-screen widgets alive
            NowPlayingWidget()
            ContinueReadingWidget()
            LibraryWidget()
        }
        if #available(iOS 16.1, *) {
            NowPlayingLockScreenWidget()    // iOS 16+ lock-screen (.accessoryCircular/Rectangular/Inline)
        }
        if #available(iOS 16.2, *) {
            ConversionLiveActivityWidget()  // iOS 16.2+ Live Activity for conversion progress
        }
    }
}
