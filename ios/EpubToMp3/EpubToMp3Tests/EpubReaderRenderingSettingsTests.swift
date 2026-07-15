import XCTest
import CoreGraphics
@testable import EpubToMp3

final class EpubReaderRenderingSettingsTests: XCTestCase {
    func testInlineImageUsesSameAspectRatioAndFitsBothRepresentations() {
        let source = EpubInlineImageSource(identifier: "figure-1", pixelSize: CGSize(width: 1600, height: 900))
        let renderer = EpubInlineImageRenderer(maxWidth: 320)

        let paginated = renderer.layout(source, representation: .paginated)
        let scrolling = renderer.layout(source, representation: .scrolling)

        XCTAssertEqual(paginated.displaySize, CGSize(width: 320, height: 180))
        XCTAssertEqual(scrolling.displaySize, paginated.displaySize)
        XCTAssertEqual(paginated.sourceIdentifier, "figure-1")
    }

    func testInlineImageTapProducesZoomPresentationContract() {
        let source = EpubInlineImageSource(identifier: "figure-1", pixelSize: CGSize(width: 800, height: 600))
        let model = EpubImageZoomModel()

        XCTAssertEqual(model.presentation, .none)
        model.tap(source)
        XCTAssertEqual(model.presentation, .zoomed(sourceIdentifier: "figure-1"))
        model.dismiss()
        XCTAssertEqual(model.presentation, .none)
    }

    func testFontChoicesIncludeBookGeorgiaSystemAndCustomAndPreviewFamily() {
        let choices: [EpubFontChoice] = [.book, .georgia, .system, .custom(family: "Alegreya")]

        XCTAssertEqual(choices.map(\.displayName), [
            "Usar fonte do livro", "Georgia", "SF", "Alegreya"
        ])
        XCTAssertEqual(choices.map(\.previewFamilyName), [nil, "Georgia", ".SFUI-Regular", "Alegreya"])
    }

    func testChangingFamilyPreservesBoldItalicHeadingAndOtherTraits() {
        let traits: EpubTextTraits = [.bold, .italic, .heading, .underline, .link]
        let resolved = EpubFontResolver.resolve(family: .georgia, size: 22, preserving: traits)

        XCTAssertEqual(resolved.family, "Georgia")
        XCTAssertEqual(resolved.pointSize, 22)
        XCTAssertEqual(resolved.traits, traits)
    }

    func testBundledAndCustomFontRegistrationMetadataIsStable() {
        let bundled = EpubFontRegistrationMetadata(resourceName: "Alegreya-Regular", fileExtension: "ttf", source: .bundled)
        let custom = EpubFontRegistrationMetadata(resourceName: "MyFont", fileExtension: "otf", source: .custom)

        XCTAssertEqual(bundled.registrationKey, "bundled:Alegreya-Regular.ttf")
        XCTAssertEqual(custom.registrationKey, "custom:MyFont.otf")
        XCTAssertEqual(bundled.source, .bundled)
        XCTAssertEqual(custom.source, .custom)
    }

    func testTypographySettingsExposeSizeSpacingMarginsAndAlignment() {
        let settings = EpubTypographySettings(fontSize: 20, lineSpacing: 8, margins: 24, alignment: .left)

        XCTAssertEqual(settings.fontSize, 20)
        XCTAssertEqual(settings.lineSpacing, 8)
        XCTAssertEqual(settings.margins, 24)
        XCTAssertEqual(settings.alignment, .left)
    }

    func testPdfDisablesEveryEpubTypographyControlButKeepsPdfLayout() {
        let policy = EpubReaderSettingsPolicy(documentKind: .pdf)

        XCTAssertFalse(policy.allows(.fontChoice))
        XCTAssertFalse(policy.allows(.fontSize))
        XCTAssertFalse(policy.allows(.lineSpacing))
        XCTAssertFalse(policy.allows(.margins))
        XCTAssertFalse(policy.allows(.alignment))
        XCTAssertTrue(policy.preservesOriginalLayout)
    }

    func testEpubAllowsEveryTypographyControl() {
        let policy = EpubReaderSettingsPolicy(documentKind: .epub)

        XCTAssertTrue(policy.allows(.fontChoice))
        XCTAssertTrue(policy.allows(.fontSize))
        XCTAssertTrue(policy.allows(.lineSpacing))
        XCTAssertTrue(policy.allows(.margins))
        XCTAssertTrue(policy.allows(.alignment))
        XCTAssertFalse(policy.preservesOriginalLayout)
    }

    func testPinchClampsFontSizeToReaderBounds() {
        var pinch = EpubFontPinchController(initialSize: 20, minimumSize: 14, maximumSize: 28)
        let now = Date(timeIntervalSince1970: 100)

        pinch.begin(at: now)
        XCTAssertEqual(pinch.update(scale: 0.1, at: now), 14)
        pinch.begin(at: now)
        XCTAssertEqual(pinch.update(scale: 10, at: now), 28)
    }

    func testPinchDebouncesCommitUntilQuietPeriod() {
        var pinch = EpubFontPinchController(initialSize: 20, minimumSize: 14, maximumSize: 28, debounce: 0.25)
        let start = Date(timeIntervalSince1970: 200)

        pinch.begin(at: start)
        XCTAssertEqual(pinch.update(scale: 1.2, at: start), 24)
        XCTAssertEqual(pinch.committedSize, 20)
        XCTAssertNil(pinch.commitIfSettled(at: start.addingTimeInterval(0.249)))
        XCTAssertEqual(pinch.commitIfSettled(at: start.addingTimeInterval(0.25)), 24)
        XCTAssertEqual(pinch.committedSize, 24)
    }

    func testPinchUpdatesResetDebounceWindow() {
        var pinch = EpubFontPinchController(initialSize: 20, minimumSize: 14, maximumSize: 28, debounce: 0.25)
        let start = Date(timeIntervalSince1970: 300)

        pinch.begin(at: start)
        _ = pinch.update(scale: 1.1, at: start)
        _ = pinch.update(scale: 1.3, at: start.addingTimeInterval(0.2))

        XCTAssertNil(pinch.commitIfSettled(at: start.addingTimeInterval(0.449)))
        XCTAssertEqual(pinch.commitIfSettled(at: start.addingTimeInterval(0.45)), 26)
    }
}
