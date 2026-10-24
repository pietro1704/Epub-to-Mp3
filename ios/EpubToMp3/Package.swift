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

let production = [
    "Features/Library/Services/BookContentIdentity.swift",
    "Features/Offline/Services/RustConversionOutputStore.swift",
    "Features/Conversion/Models/SessionRecord.swift",
    "Features/Conversion/Services/ConversionHistoryReader.swift",
    "Features/Conversion/Services/AudioEnginePreference.swift",
    "Features/Conversion/Services/ConversionChapterSelection.swift",
    "Features/Conversion/Services/ConversionOptions.swift",
    "Features/Conversion/Services/PlatformSpeechSynthesizer.swift",
    "Features/Conversion/Services/PlatformFallbackNotice.swift",
    "Features/Conversion/Services/ConverterFFIAdapter.swift",
    "Features/Conversion/Services/ConverterABISignatures.swift",
    "Features/Conversion/Services/EmbeddedConverterError.swift",
    "Features/Conversion/Services/ConverterModelCatalog.swift",
    "Features/Conversion/Services/ConverterCallbackBridge.swift",
    "Features/Conversion/Services/ConverterPlaybackControl.swift",
    "Features/Conversion/Services/ReaderConversionChapterMap.swift",
    "Features/Conversion/Services/TtsCatalog.swift",
    "Features/Reader/Models/EbookFulltext.swift",
    "Features/Documents/Services/EpubArchivePath.swift",
    "Features/Conversion/Services/ConversionCallbackReceipt.swift",
    "Features/Conversion/Services/RustConversionCoordinator.swift",
    "Features/Conversion/Services/RustConversionEvents.swift",
    "Features/Conversion/Services/RustConversionResult.swift",
    "Features/Conversion/Models/JobSnapshot.swift",
    "Shared/Localization/L10n.swift",
]
let tests = [
    "BookContentIdentityTests.swift",
    "PlatformSpeechSynthesizerTests.swift",
    "ConversionHistoryReaderTests.swift",
    "ConversionChapterSelectionTests.swift",
    "ConversionOptionsInteropTests.swift",
    "ConversionOptionsInteropReadinessAdmissionTests.swift",
    "ConversionOptionsInteropWireIdentityTests.swift",
    "ConversionOptionsInteropOptInProviderJourneyTests.swift",
    "ConverterModelCatalogOwnershipTests.swift",
    "EpubFixture.swift",
    "ReaderConversionChapterMapTests.swift",
    "ReaderListeningControlTests.swift",
]
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
