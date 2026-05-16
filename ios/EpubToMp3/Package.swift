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

import PackageDescription

let package = Package(
    name: "EpubToMp3",
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
                "Views",
                "Resources",
                "Services/PdfTextExtractor.swift",
            ]
        ),
        .testTarget(
            name: "EpubToMp3Tests",
            dependencies: ["EpubToMp3"],
            path: "EpubToMp3Tests",
            exclude: [
                "LibraryDragDropTests.swift",
                "MainReaderViewTests.swift",
                "NowPlayingViewTests.swift",
                "PdfTextExtractorTests.swift",
                "PlatformCompatTests.swift",
                "SplitViewRootTests.swift",
            ]
        ),
    ]
)
