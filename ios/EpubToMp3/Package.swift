// swift-tools-version:5.9
//
// This Package.swift exists ONLY so the non-UI Swift sources (Models, Services)
// can be type-checked locally with `swift build` without needing Xcode or an
// iOS SDK. SwiftUI views target iOS and live in the `EpubToMp3App` target,
// which is built by Xcode (see ios/README.md).
//
// `swift build` from the host platform will compile `EpubToMp3Core` (Models +
// Services) using the macOS SDK — Foundation-only code, no SwiftUI imports —
// to validate the API contract and JSON decoding before opening Xcode.

import PackageDescription

let package = Package(
    name: "EpubToMp3Core",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "EpubToMp3Core", targets: ["EpubToMp3Core"]),
    ],
    targets: [
        .target(
            name: "EpubToMp3Core",
            path: "EpubToMp3",
            exclude: [
                "EpubToMp3App.swift",
                "Models/AppSettings.swift",   // depends on SwiftUI
                "Views",
                "Resources",
            ],
            sources: [
                "Models/SessionRecord.swift",
                "Services/APIClient.swift",
            ]
        ),
    ]
)
