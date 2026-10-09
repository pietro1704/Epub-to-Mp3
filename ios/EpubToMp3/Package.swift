// swift-tools-version: 5.9
import Foundation
import PackageDescription

// Compile the same Foundation-only production files without launching an app.
func excludedFiles(_ directory: String, keeping sources: [String]) -> [String] {
    let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(directory)
    let paths = FileManager.default.enumerator(atPath: base.path)?.allObjects as? [String] ?? []
    return (directory == "EpubToMp3" ? ["Assets.xcassets"] : []) + paths.filter { path in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: base.appendingPathComponent(path).path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && !sources.contains(path)
    }
}

let production = ["Features/Conversion/Models/SessionRecord.swift", "Features/Conversion/Services/ConversionHistoryReader.swift",
                  "Features/Conversion/Services/ConversionChapterSelection.swift", "Features/Conversion/Services/ConversionOptions.swift",
                  "Features/Conversion/Services/ConverterFFIAdapter.swift", "Features/Conversion/Services/RustConversionCoordinator.swift",
                  "Features/Conversion/Models/JobSnapshot.swift", "Shared/Localization/L10n.swift"]
let tests = ["ConversionHistoryReaderTests.swift", "ConversionChapterSelectionTests.swift", "ConversionOptionsInteropTests.swift", "EpubFixture.swift"]
let package = Package(
    name: "AppFoundation",
    platforms: [.macOS(.v12)],
    targets: [
        .target(name: "AppFoundation", path: "EpubToMp3",
                exclude: excludedFiles("EpubToMp3", keeping: production), sources: production),
        .testTarget(name: "AppFoundationTests", dependencies: ["AppFoundation"], path: "EpubToMp3Tests",
                    exclude: excludedFiles("EpubToMp3Tests", keeping: tests), sources: tests,
                    swiftSettings: [.define("APP_FOUNDATION_HOST_TESTS")]),
    ],
    swiftLanguageVersions: [.v5]
)
