#if os(macOS)
import AppKit

if EpubToMp3App.isRunningUnderXCTest() {
    while NSApp == nil {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }
    NSApp?.run()
} else {
    EpubToMp3App.runApp()
}
#else
import UIKit

UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(EpubToMp3App.self)
)
#endif
