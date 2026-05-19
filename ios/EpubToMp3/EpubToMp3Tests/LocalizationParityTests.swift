import XCTest

/// Regression guard for the three `Localizable.strings` tables
/// (en, pt-BR, es). Every user-facing string in the SwiftUI app and the
/// widget extension routes through a key in these tables; if a key
/// exists in one locale but not another, that locale silently renders
/// the raw key. This test fails the build before that ships.
///
/// Run locally with:
///   xcodebuild test -scheme EpubToMp3 -destination 'platform=macOS' \
///     -only-testing EpubToMp3Tests/LocalizationParityTests
final class LocalizationParityTests: XCTestCase {

    private static let locales = ["en", "pt-BR", "es"]

    // MARK: - Helpers

    /// Resolves a `.strings` table. Prefers the test/app bundle so the
    /// test works for normal `xcodebuild test`; falls back to the source
    /// tree (relative to `#filePath`) for command-line invocations.
    private func tableURL(locale: String) -> URL? {
        if let url = Bundle(for: type(of: self))
            .url(forResource: "Localizable", withExtension: "strings",
                 subdirectory: nil, localization: locale) {
            return url
        }
        if let url = Bundle.main
            .url(forResource: "Localizable", withExtension: "strings",
                 subdirectory: nil, localization: locale) {
            return url
        }
        // Source tree: …/EpubToMp3Tests/ -> …/ -> EpubToMp3/Resources/…
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // EpubToMp3Tests/
            .deletingLastPathComponent()   // project root
            .appendingPathComponent("EpubToMp3/Resources/\(locale).lproj/Localizable.strings")
        return FileManager.default.fileExists(atPath: base.path) ? base : nil
    }

    /// Parses a `.strings` table (ASCII or UTF-16-BOM) into a dictionary.
    private func loadTable(locale: String) throws -> [String: String] {
        guard let url = tableURL(locale: locale) else {
            XCTFail("Could not locate \(locale).lproj/Localizable.strings")
            return [:]
        }
        let data = try Data(contentsOf: url)
        guard let dict = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: String]
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return dict
    }

    private func loadAllTables() throws -> [String: [String: String]] {
        try Self.locales.reduce(into: [:]) { $0[$1] = try loadTable(locale: $1) }
    }

    // MARK: - Tests

    /// All three tables exist and parse to a non-empty dictionary.
    func testAllTablesParse() throws {
        for locale in Self.locales {
            let table = try loadTable(locale: locale)
            XCTAssertFalse(table.isEmpty, "\(locale) table parsed empty")
        }
    }

    /// The three key sets are byte-for-byte identical.
    func testKeySetsAreIdentical() throws {
        let tables = try loadAllTables()
        let reference = Set(tables["en"]!.keys)

        for locale in Self.locales where locale != "en" {
            let keys = Set(tables[locale]!.keys)
            let missing = reference.subtracting(keys).sorted()
            let extra = keys.subtracting(reference).sorted()
            XCTAssertTrue(
                missing.isEmpty,
                "\(locale) is missing keys present in en:\n\(missing.joined(separator: "\n"))"
            )
            XCTAssertTrue(
                extra.isEmpty,
                "\(locale) has keys absent from en (orphans):\n\(extra.joined(separator: "\n"))"
            )
        }
    }

    /// No value in any table is empty or whitespace-only.
    func testNoValuesAreEmpty() throws {
        for locale in Self.locales {
            let table = try loadTable(locale: locale)
            let empty = table
                .filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .keys.sorted()
            XCTAssertTrue(empty.isEmpty, "\(locale) keys with empty values: \(empty)")
        }
    }

    /// Format-specifier parity: a key whose en value carries `%@` / `%d`
    /// placeholders must carry the same count in pt-BR and es, otherwise
    /// `String(format:)` crashes or drops an argument at runtime.
    func testFormatSpecifierCountsMatch() throws {
        let tables = try loadAllTables()
        let en = tables["en"]!

        func specifierCount(_ value: String) -> Int {
            // Ignore escaped %% literals, then count remaining % tokens.
            let collapsed = value.replacingOccurrences(of: "%%", with: "")
            return collapsed.filter { $0 == "%" }.count
        }

        for (key, enValue) in en {
            let expected = specifierCount(enValue)
            for locale in Self.locales where locale != "en" {
                guard let localized = tables[locale]?[key] else { continue }
                XCTAssertEqual(
                    specifierCount(localized), expected,
                    "\(locale): key '\(key)' format-specifier count diverges from en"
                )
            }
        }
    }
}
