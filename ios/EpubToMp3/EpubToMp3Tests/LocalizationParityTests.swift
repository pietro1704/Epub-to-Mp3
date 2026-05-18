import XCTest

/// Regression guard: every key in en.lproj must exist in pt-BR.lproj and vice-versa.
/// Run this locally with:
///   xcodebuild test -scheme EpubToMp3 -destination 'platform=macOS' \
///     -only-testing EpubToMp3Tests/LocalizationParityTests
final class LocalizationParityTests: XCTestCase {

    // MARK: - Helpers

    private func loadKeys(locale: String) throws -> Set<String> {
        guard let url = Bundle(for: type(of: self))
            .url(forResource: "Localizable", withExtension: "strings",
                 subdirectory: nil, localization: locale)
        else {
            // Fall back to searching the main app bundle (needed when tests run inside the app target)
            guard let appURL = Bundle.main
                .url(forResource: "Localizable", withExtension: "strings",
                     subdirectory: nil, localization: locale)
            else {
                // Last resort: resolve path relative to the source tree so
                // command-line xcodebuild invocations can find the files too.
                let base = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()          // EpubToMp3Tests/
                    .deletingLastPathComponent()          // EpubToMp3/
                    .appendingPathComponent("EpubToMp3/Resources/\(locale).lproj/Localizable.strings")
                return try keysFromFile(at: base)
            }
            return try keysFromFile(at: appURL)
        }
        return try keysFromFile(at: url)
    }

    private func keysFromFile(at url: URL) throws -> Set<String> {
        let data = try Data(contentsOf: url)
        // NSDictionary parses .strings (both ASCII and UTF-16 BOM formats)
        guard let dict = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: String]
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return Set(dict.keys)
    }

    // MARK: - Tests

    func testEnAndPtBRHaveIdenticalKeysets() throws {
        let en   = try loadKeys(locale: "en")
        let ptBR = try loadKeys(locale: "pt-BR")

        let missingInPtBR = en.subtracting(ptBR).sorted()
        let missingInEn   = ptBR.subtracting(en).sorted()

        XCTAssertTrue(
            missingInPtBR.isEmpty,
            "Keys present in en but missing in pt-BR:\n\(missingInPtBR.joined(separator: "\n"))"
        )
        XCTAssertTrue(
            missingInEn.isEmpty,
            "Keys present in pt-BR but missing in en (orphans):\n\(missingInEn.joined(separator: "\n"))"
        )
    }

    func testEnHasNoEmptyValues() throws {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3/Resources/en.lproj/Localizable.strings")
        let data = try Data(contentsOf: base)
        guard let dict = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: String]
        else { throw CocoaError(.fileReadCorruptFile) }
        let empty = dict.filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.keys.sorted()
        XCTAssertTrue(empty.isEmpty, "en keys with empty values: \(empty)")
    }

    func testPtBRHasNoEmptyValues() throws {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3/Resources/pt-BR.lproj/Localizable.strings")
        let data = try Data(contentsOf: base)
        guard let dict = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: String]
        else { throw CocoaError(.fileReadCorruptFile) }
        let empty = dict.filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.keys.sorted()
        XCTAssertTrue(empty.isEmpty, "pt-BR keys with empty values: \(empty)")
    }
}
