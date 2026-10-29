import XCTest
import CoreText
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class ReaderFontCatalogTests: XCTestCase {
    func testReferenceCatalogRetainsOriginalNamedChoicesAndLegacyKeys() {
        let keys = Set(ReaderFontFamily.allCases.map(\.rawValue))
        let expected: Set<String> = ["original", "athelas", "avenirNext", "canela", "charter", "georgia",
            "iowan", "palatino", "proximaNova", "publico", "sanFrancisco", "newYork", "seravek", "timesNewRoman"]
        XCTAssertTrue(expected.isSubset(of: keys), "Missing requested reference choices: \(expected.subtracting(keys))")
        XCTAssertTrue(Set(["serif", "sans", "mono"]).isSubset(of: keys))
    }

    func testAvailabilityKeepsSystemDesignsAndDoesNotInventNamedFaces() {
        XCTAssertTrue(ReaderFontFamily.newYork.isAvailable(in: []))
        XCTAssertTrue(ReaderFontFamily.sanFrancisco.isAvailable(in: []))
        XCTAssertFalse(ReaderFontFamily.canela.isAvailable(in: ["Georgia"]))
        XCTAssertTrue(ReaderFontFamily.iowan.isAvailable(in: ["Iowan Old Style"]))
        XCTAssertFalse(ReaderFontFamily.publico.isAvailable(in: ["Publico Headline"]))
        XCTAssertEqual(ReaderFontFamily(rawValue: "serif")?.namedFamily, "Times New Roman")
        XCTAssertEqual(ReaderFontFamily(rawValue: "sans")?.namedFamily, "Helvetica Neue")
        XCTAssertEqual(ReaderFontFamily(rawValue: "mono")?.namedFamily, "Menlo")
    }

    @MainActor
    func testSystemDesignsAndAvailableNamedFamiliesResolveAtRequestedSize() {
        for family in ReaderFontFamily.allCases where family.isAvailable(in: ReaderFontCatalog.availableFamilies) {
            let font = ReaderFontCatalog.font(for: family, size: 23)
            XCTAssertEqual(font.pointSize, 23, accuracy: 0.01)
            if let expected = family.namedFamily {
                XCTAssertEqual(font.familyName, expected, "\(family.rawValue) must resolve its actual family")
            }
            let characters = Array("ação, coração, português".utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            let actual = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
            XCTAssertTrue(CTFontGetGlyphsForCharacters(actual, characters, &glyphs, characters.count))
            XCTAssertFalse(glyphs.contains(0), "\(family.rawValue) must contain the Portuguese preview glyphs")
        }
        XCTAssertNotEqual(ReaderFontCatalog.font(for: .newYork, size: 23).fontName,
                          ReaderFontCatalog.font(for: .sanFrancisco, size: 23).fontName)
    }

    @MainActor
    func testUnavailablePersistedRequestRemainsIdentifiedWhileRenderingUsesFallback() {
        guard let missing = ReaderFontFamily.allCases.first(where: { !$0.isAvailable(in: ReaderFontCatalog.availableFamilies) }) else {
            return // All named fonts are genuinely installed on this runtime.
        }
        XCTAssertTrue(ReaderFontCatalog.choices(retaining: missing).contains(missing))
        XCTAssertNotEqual(ReaderFontCatalog.title(for: missing), missing.displayName)
        XCTAssertEqual(ReaderFontCatalog.font(for: missing, size: 18).fontName,
                       ReaderFontCatalog.font(for: .newYork, size: 18).fontName)
        XCTAssertEqual(ReaderFontCatalog.choices(retaining: .original).first, .original)
    }
}
