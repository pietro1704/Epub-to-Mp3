#if os(macOS)
import AppKit

MainActor.assumeIsolated {
    if EpubToMp3App.isRunningUnderXCTest() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.run()
    } else {
        EpubToMp3App.runApp()
    }
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
