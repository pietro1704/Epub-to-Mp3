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

    func testAutoThemeResolvesDarkAquaToDarkSurfaceAndReadableText() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.readerTheme = .auto
        let surface = NSView()
        surface.appearance = NSAppearance(named: .darkAqua)
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

        let backgroundRed = textView.backgroundColor.usingColorSpace(.deviceRGB)?.redComponent ?? 1
        let foregroundRed = textView.textColor?.usingColorSpace(.deviceRGB)?.redComponent ?? 0
        XCTAssertLessThan(backgroundRed, 0.5, "Auto dark mode must not leave a white reader surface")
        XCTAssertGreaterThan(foregroundRed, 0.7, "Auto dark mode must keep reader text readable")
        XCTAssertEqual(scrollView.backgroundColor, textView.backgroundColor)
        XCTAssertEqual(title.textColor, textView.textColor)
    }

    func testEveryReaderThemeProducesOpaqueContrastingMacOSColours() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)

        for theme in ReaderTheme.allCases {
            settings.readerTheme = theme
            let surface = NSView()
            surface.appearance = NSAppearance(named: theme == .auto ? .darkAqua : .aqua)
            let textView = NSTextView()

            MacReaderTheme.apply(
                settings: settings,
                surface: surface,
                scrollView: NSScrollView(),
                textView: textView
            )

            let background = textView.backgroundColor.usingColorSpace(.deviceRGB)
            let foreground = textView.textColor?.usingColorSpace(.deviceRGB)
            XCTAssertNotNil(background, "\(theme.rawValue) must provide a readable background")
            XCTAssertNotNil(foreground, "\(theme.rawValue) must provide readable text")
            XCTAssertGreaterThan(
                abs((background?.redComponent ?? 0) - (foreground?.redComponent ?? 0)),
                0.15,
                "\(theme.rawValue) must keep foreground and background visually distinct"
            )
        }
    }
}
#endif
