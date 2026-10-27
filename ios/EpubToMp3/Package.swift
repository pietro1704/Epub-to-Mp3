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

let localizationResources = [
    "Resources/en.lproj/Localizable.strings",
    "Resources/es.lproj/Localizable.strings",
    "Resources/pt-BR.lproj/Localizable.strings",
]
let production = [
    "Features/Playback/Models/PlayerVisibilityTransition.swift",
    "Features/Playback/Models/PlayerDismissalDecision.swift",
    "Features/Playback/Models/ChapterPlaybackTimeline.swift",
    "Features/Conversion/Services/ManualConversionSession.swift",
    "Features/Conversion/Services/ManualConversionPresentation.swift",
    "Features/Conversion/Services/RustConversionWorkQueues.swift",
    "Features/Playback/Services/InAppPlaybackRequest.swift",
    "Features/Library/Services/BookContentIdentity.swift",
    "Features/Offline/Services/RustConversionOutputStore.swift",
    "Features/Conversion/Models/SessionRecord.swift",
    "Features/Conversion/Services/ConversionHistoryReader.swift",
    "Features/Conversion/Services/AudioEnginePreference.swift",
    "Features/Conversion/Services/ConversionChapterSelection.swift",
    "Features/Conversion/Services/ConversionOptions.swift",
    "Features/Conversion/Services/BookConversionRecoveryStore.swift",
    "Features/Conversion/Services/BookPronunciationStore.swift",
    "Features/Conversion/Services/VoiceAuditionController.swift",
    "Features/Conversion/Services/RenderProgressPresentation.swift",
    "Features/Conversion/Services/PlatformSpeechSynthesizer.swift",
    "Features/Conversion/Services/PlatformFallbackNotice.swift",
    "Features/Conversion/Services/ConverterFFIAdapter.swift",
    "Features/Conversion/Services/ConverterABISignatures.swift",
    "Features/Conversion/Services/EmbeddedConverterError.swift",
    "Features/Conversion/Services/ConverterModelCatalog.swift",
    "Features/Conversion/Services/ConverterModelInstallOperation.swift",
    "Features/Conversion/Services/SpeechModelBackgroundTransfer.swift",
    "Features/Conversion/Services/SpeechModelRangeDownload.swift",
    "Features/Conversion/Services/SpeechModelLibraryClient.swift",
    "Features/Conversion/Services/SpeechModelLibraryViewState.swift",
    "Features/Conversion/Services/SpeechModelPresentationStore.swift",
    "Features/Conversion/Services/SpeechModelSnapshot.swift",
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
    "Shared/Configuration/LocalSpeechModelReadiness.swift",
]
let tests = [
    "PlayerVisibilityTransitionTests.swift",
    "PlayerDismissalDecisionTests.swift",
    "ChapterPlaybackTimelineTests.swift",
    "ManualConversionSessionTests.swift",
    "RustConversionWorkQueuesTests.swift",
    "InAppPlaybackRequestTests.swift",
    "BackgroundAudioConfigurationTests.swift",
    "BookContentIdentityTests.swift",
    "BookConversionRecoveryTests.swift",
    "BookPronunciationTests.swift",
    "VoiceAuditionControllerTests.swift",
    "PlatformSpeechSynthesizerTests.swift",
    "ConversionHistoryReaderTests.swift",
    "ConversionChapterSelectionTests.swift",
    "ConversionOptionsInteropTests.swift",
    "ConversionOptionsInteropReadinessAdmissionTests.swift",
    "ConversionOptionsInteropWireIdentityTests.swift",
    "ConversionOptionsInteropOptInProviderJourneyTests.swift",
    "ConverterModelCatalogOwnershipTests.swift",
    "SpeechModelBackgroundTransferTests.swift",
    "SpeechModelArtifactAcceptanceTests.swift",
    "SpeechModelRangeDownloadTests.swift",
    "SpeechModelRangeHTTPFixture.swift",
    "SpeechModelRangeHTTPTests.swift",
    "SpeechModelRangeCrashTests.swift",
    "SpeechModelLibraryClientTests.swift",
    "SpeechModelStudyLanguageTests.swift",
    "SpeechModelVoicePresentationTests.swift",
    "EpubFixture.swift",
    "ReaderConversionChapterMapTests.swift",
    "ReaderListeningControlTests.swift",
]
let package = Package(
    name: "AppFoundation",
    defaultLocalization: "en",
    platforms: [.macOS(.v12)],
    targets: [
        .target(name: "AppFoundation", path: "EpubToMp3",
                exclude: excludedFiles("EpubToMp3", keeping: production + localizationResources),
                sources: production,
                resources: localizationResources.map { .process($0) }),
        .testTarget(name: "AppFoundationTests", dependencies: ["AppFoundation"], path: "EpubToMp3Tests",
                    exclude: excludedFiles("EpubToMp3Tests", keeping: tests), sources: tests,
                    swiftSettings: [.define("APP_FOUNDATION_HOST_TESTS")]),
    ],
    swiftLanguageVersions: [.v5]
)
