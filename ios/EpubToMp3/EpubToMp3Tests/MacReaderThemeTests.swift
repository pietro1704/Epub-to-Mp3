#if os(macOS) && !targetEnvironment(simulator)
import AppKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MacReaderThemeTests: XCTestCase {
    func testLightThemeMakesReaderSurfaceOpaqueAndReadable() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.readerTheme = .light
        let surface = NSView()
        let scrollView = NSScrollView()
        let textView = NSTextView()
        let toolbar = NSView()
        let title = NSTextField(labelWithString: "Chapter 10: Strider")

        MacReaderTheme.apply(
            settings: settings,
            surface: surface,
            scrollView: scrollView,
            textView: textView,
            toolbar: toolbar,
            labels: [title]
        )

        XCTAssertTrue(scrollView.drawsBackground)
        XCTAssertTrue(textView.drawsBackground)
        XCTAssertEqual(textView.backgroundColor, .white)
        XCTAssertEqual(textView.textColor, .black)
        XCTAssertEqual(scrollView.backgroundColor, .white)
        XCTAssertEqual(title.textColor, .black)
        XCTAssertEqual(toolbar.layer?.backgroundColor, NSColor.white.cgColor)
    }

    func testAutoThemeResolvesSurfaceAndTitleUsingOneAppearance() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.readerTheme = .auto
        let surface = NSView()
        surface.appearance = NSAppearance(named: .aqua)
        let title = NSTextField(labelWithString: "Chapter 10: Strider")

        MacReaderTheme.apply(
            settings: settings,
            surface: surface,
            scrollView: NSScrollView(),
            textView: NSTextView(),
            labels: [title]
        )

        XCTAssertEqual(surface.layer?.backgroundColor, NSColor.white.cgColor)
        XCTAssertEqual(title.textColor, .black)
    }
}
#endif
