// swift-tools-version: 5.9
import Foundation
import PackageDescription

// Compile the same Foundation-only production files without launching an app.
func excludedFiles(_ directory: String, keeping sources: [String]) -> [String] {
    let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(directory)
    let paths = FileManager.default.enumerator(atPath: base.path)?.allObjects as? [String] ?? []
    return paths.filter { path in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: base.appendingPathComponent(path).path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && !sources.contains(path)
    }
}

let production = ["Models/SessionRecord.swift", "Services/ConversionHistoryReader.swift", "Services/ConversionChapterSelection.swift"]
let tests = ["ConversionHistoryReaderTests.swift", "ConversionChapterSelectionTests.swift"]
let package = Package(
    name: "AppFoundation",
    platforms: [.macOS(.v12)],
    targets: [
        .target(name: "AppFoundation", path: "EpubToMp3/Features/Conversion",
                exclude: excludedFiles("EpubToMp3/Features/Conversion", keeping: production), sources: production),
        .testTarget(name: "AppFoundationTests", dependencies: ["AppFoundation"], path: "EpubToMp3Tests",
                    exclude: excludedFiles("EpubToMp3Tests", keeping: tests), sources: tests,
                    swiftSettings: [.define("APP_FOUNDATION_HOST_TESTS")]),
    ],
    swiftLanguageVersions: [.v5]
)
