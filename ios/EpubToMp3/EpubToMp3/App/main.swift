#if os(macOS)
import AppKit

EpubToMp3App.runApp()
#else
import UIKit

UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(EpubToMp3App.self)
)
#endif
