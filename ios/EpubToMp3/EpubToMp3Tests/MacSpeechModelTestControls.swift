#if os(macOS)
import AppKit
import XCTest

@MainActor
enum MacSpeechModelTestControls {
    /// Follow the public control instead of bypassing the collapsed presentation.
    static func revealModels(in view: NSView, file: StaticString = #filePath, line: UInt = #line) throws {
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let disclosure = try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "settings.speechModels.disclosure" },
            file: file, line: line)
        disclosure.performClick(nil)
    }
}
#endif
