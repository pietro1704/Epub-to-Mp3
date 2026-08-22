#if canImport(AppKit)
import AppKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MacReaderAppearanceTests: XCTestCase {
    func testDarkThemeUsesDarkTextSurfaceWithLightText() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.readerTheme = .dark

        let appearance = MacReaderAppearance.resolve(settings: settings)

        XCTAssertLessThan(appearance.background.whiteComponent, 0.2)
        XCTAssertGreaterThan(appearance.foreground.whiteComponent, 0.8)
    }
}

private extension NSColor {
    var whiteComponent: CGFloat {
        let color = usingColorSpace(.deviceRGB)!
        return (color.redComponent + color.greenComponent + color.blueComponent) / 3
    }
}
#endif
