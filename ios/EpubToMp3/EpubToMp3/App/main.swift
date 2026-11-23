#if os(macOS)
import AppKit

// Launch-only test isolation must be in place before anything touches the library, caches or defaults.
AppIsolation.activateIfRequested()

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

AppIsolation.activateIfRequested()

UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(EpubToMp3App.self)
)
#endif
