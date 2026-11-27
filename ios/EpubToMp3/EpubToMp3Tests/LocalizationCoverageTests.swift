import XCTest
@testable import EpubToMp3

final class LocalizationCoverageTests: XCTestCase {
    func testSupportedLocalesHaveEveryEnglishKeyAndMatchingFormatArguments() throws {
        let bundle = Bundle(for: AppSettings.self)
        func table(_ locale: String, _ name: String) throws -> [String: String] {
            let path = try XCTUnwrap(bundle.path(forResource: name, ofType: "strings", inDirectory: nil, forLocalization: locale))
            let contents = try Data(contentsOf: URL(fileURLWithPath: path))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: contents, format: nil) as? [String: String])
        }
        let format = try NSRegularExpression(pattern: #"%(?:[0-9]+\$)?(?:@|[diufg]|l[diu]|ll[diu])"#)
        func arguments(_ value: String) -> [String] {
            format.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                (value as NSString).substring(with: $0.range)
            }.sorted()
        }
        for name in ["Localizable", "AppShortcuts"] {
            let reference = try table("en", name)
            for locale in ["pt-BR", "es"] {
                let localized = try table(locale, name)
                XCTAssertEqual(Set(localized.keys), Set(reference.keys), "\(locale): \(name)")
                for (key, value) in reference {
                    let translated = try XCTUnwrap(localized[key], key)
                    XCTAssertFalse(translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key)
                    XCTAssertEqual(arguments(translated), arguments(value), "\(locale): \(key)")
                }
            }
        }
    }

    /// JOBS-EMPTY-COPY: the empty history points to the app's own Convert screen, not to other clients.
    func testEmptyJobHistoryPointsToTheConvertScreen() throws {
        defer { L10n.bundleOverrideForTesting = nil }
        for locale in ["en", "pt-BR", "es"] {
            L10n.bundleOverrideForTesting = try XCTUnwrap(L10n.localizationBundle(locale), "\(locale).lproj missing")
            let copy = L10n.string("jobs.noConversionsDescription")
            XCTAssertTrue(copy.contains(L10n.string("convert.title")), "\(locale): \(copy)")
            XCTAssertFalse(copy.contains("CLI"), "\(locale): \(copy)")
            XCTAssertFalse(copy.lowercased().contains("web"), "\(locale): \(copy)")
        }
    }
}
