#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// Converter, Settings and Reading preferences host their forms in `MacScrollableStack`. A form with a
/// maximum width must stay centred in a wide window instead of shrinking the window the user sized.
@MainActor
final class MacScrollableStackWindowTests: XCTestCase {
    // 900 pt fits the 1024 pt screen of the CI runner; AppKit shrinks wider windows to the screen.
    func testAWideWindowKeepsItsWidthAroundAWidthCappedForm() {
        let (window, stack) = hostForm(maximumWidth: 620, windowWidth: 900)
        defer { close(window) }

        XCTAssertEqual(window.contentLayoutRect.width, 900, accuracy: 1, "the page must not resize the window")
        XCTAssertEqual(stack.frame.width, 620, accuracy: 1, "the form stops at its maximum width")
    }

    func testANarrowWindowStillStretchesTheFormToItsMargins() {
        let (window, stack) = hostForm(maximumWidth: 620, windowWidth: 500)
        defer { close(window) }

        XCTAssertEqual(window.contentLayoutRect.width, 500, accuracy: 1)
        XCTAssertEqual(stack.frame.width, 452, accuracy: 1, "24 pt margins on both sides")
    }

    private func hostForm(maximumWidth: CGFloat, windowWidth: CGFloat) -> (NSWindow, NSStackView) {
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: 600))
        let stack = NSStackView(views: [NSTextField(labelWithString: "Synthetic row")])
        stack.orientation = .vertical
        stack.alignment = .leading
        MacScrollableStack.install(stack, in: controller.view, maximumWidth: maximumWidth)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: windowWidth, height: 600))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        return (window, stack)
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
    }
}
#endif
