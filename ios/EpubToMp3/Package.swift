// swift-tools-version:5.9
//
// This Package.swift exists ONLY so the non-UI Swift sources (Models, Services)
// can be type-checked locally with `swift build` without needing Xcode or an
// iOS SDK. SwiftUI views target iOS and live in the `EpubToMp3App` target,
// which is built by Xcode (see ios/README.md).
//
// `swift build` from the host platform will compile `EpubToMp3` (Models +
// Services) using the macOS SDK — Foundation-only code, no SwiftUI imports —
// to validate the API contract and JSON decoding before opening Xcode.
//
// AudioPlayer.swift IS included here: AVFoundation + MediaPlayer are
// available on macOS too, and the file is guarded by `#if canImport(...)`.
// Tests live in `EpubToMp3Tests/` and exercise pure-logic helpers
// (ResumeStore, JobSnapshot decoding, DownloadManager filename sanitisation).

import PackageDescription

let package = Package(
    name: "EpubToMp3",
    // macOS 14 + iOS 17 share the Observation framework (`@Observable`).
    // The host SPM build only exists for headless contract validation; the
    // shipping target is iOS 17.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "EpubToMp3", targets: ["EpubToMp3"]),
    ],
    targets: [
        .target(
            name: "EpubToMp3",
            path: "EpubToMp3",
            exclude: [
                "EpubToMp3App.swift",
                "Models/AppSettings.swift",   // depends on SwiftUI
                "Views",
                "Resources",
            ],
            sources: [
                "Models/SessionRecord.swift",
                "Models/JobSnapshot.swift",
                "Models/EbookFulltext.swift",
                "Models/BookEntity.swift",
                "Services/APIClient.swift",
                "Services/AudioPlayer.swift",
                "Services/DownloadManager.swift",
                "Services/FulltextStore.swift",
                "Services/ResumeStore.swift",
                "Services/SyncEngine.swift",
                "Services/LibraryStore.swift",
                "Services/EpubMetadataReader.swift",
                "Services/SidecarManager.swift",
            ]
        ),
        .testTarget(
            name: "EpubToMp3Tests",
            dependencies: ["EpubToMp3"],
            path: "EpubToMp3Tests"
        ),
    ]
)
