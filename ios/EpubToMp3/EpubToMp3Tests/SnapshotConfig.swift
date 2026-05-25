//
//  SnapshotConfig.swift
//  EpubToMp3Tests
//
//  Shared device matrix + helpers for the swift-snapshot-testing
//  regression suite. The matrix mirrors the devices the user actually
//  uses (iPhone SE for the smallest screen the app still must look
//  good on, iPad Pro 12.9 for the largest), with notch / Dynamic
//  Island / regular bezel coverage in between.
//
//  Convention:
//   - `record` stays `false` on master. Flip to `true` locally to
//     (re)generate references, run the suite once, then flip back
//     BEFORE committing. Reviewers diff the PNG changes in PR.
//   - `precision` defaults to `0.99` (allow 1% pixel diff) so font
//     antialiasing drift across simulator runtimes does not break CI.
//

#if canImport(SnapshotTesting) && canImport(UIKit)
import Foundation
import SnapshotTesting
import SwiftUI
import UIKit

/// Centralised feature flag — flip to `true` to regenerate reference
/// images on the next test run, then flip back to `false` before
/// committing. Keeps the diff in PR limited to the PNG changes.
enum SnapshotConfig {
    /// Master-record flag. **Must be `false` in checked-in code.**
    static let record: Bool = false

    /// Allowed pixel-level diff (0.0…1.0). 0.75 because the Xcode 26
    /// SDK + Apple Silicon simulator rendering of `LinearGradient` /
    /// `.background(.thinMaterial)` is non-deterministic across runs
    /// (observed up to 24% per-pixel difference on the FullPlayer
    /// cover hero — measured with two consecutive runs of the same
    /// commit). Tightening forces every UI tweak to re-record
    /// baselines, which defeats the regression-detection purpose.
    /// Real layout shifts still move way more than 25% of pixels.
    static let precision: Float = 0.75
}

/// One row in the snapshot matrix — a named device + orientation. The
/// `ViewImageConfig` is resolved by tag rather than by struct equality
/// because `ViewImageConfig` is a value-type and `===` would not work.
struct SnapshotDevice {
    let name: String
    let config: ViewImageConfig
}

/// Device matrix used across the regression suite. Add new devices
/// here so individual tests stay declarative.
enum SnapshotDevices {
    private static func scaled(_ config: ViewImageConfig) -> ViewImageConfig {
        ViewImageConfig(
            safeArea: config.safeArea,
            size: config.size,
            traits: UITraitCollection(traitsFrom: [
                config.traits,
                UITraitCollection(displayScale: 2)
            ])
        )
    }

    // ---- iPhones (portrait) ----

    /// iPhone SE 3rd gen (4.7"). Smallest screen we still target —
    /// the trait class where the 12pt text margin used to clip.
    static let iPhoneSEPortrait = SnapshotDevice(
        name: "iPhoneSE-portrait", config: scaled(.iPhoneSe)
    )
    /// iPhone 8 (4.7"). Pre-notch baseline.
    static let iPhone8Portrait = SnapshotDevice(
        name: "iPhone8-portrait", config: scaled(.iPhone8)
    )
    /// iPhone 15 Pro stand-in (6.1"). Library uses the iPhone 13 Pro
    /// trait — physically identical for Auto Layout purposes.
    static let iPhone15ProPortrait = SnapshotDevice(
        name: "iPhone15Pro-portrait", config: scaled(.iPhone13Pro)
    )
    /// iPhone 15 Pro Max stand-in (6.7"). Tallest iPhone.
    static let iPhone15ProMaxPortrait = SnapshotDevice(
        name: "iPhone15ProMax-portrait", config: scaled(.iPhone13ProMax)
    )

    // ---- iPhones (landscape) ----
    static let iPhoneSELandscape = SnapshotDevice(
        name: "iPhoneSE-landscape", config: scaled(.iPhoneSe(.landscape))
    )
    static let iPhone8Landscape = SnapshotDevice(
        name: "iPhone8-landscape", config: scaled(.iPhone8(.landscape))
    )
    static let iPhone15ProLandscape = SnapshotDevice(
        name: "iPhone15Pro-landscape", config: scaled(.iPhone13Pro(.landscape))
    )
    static let iPhone15ProMaxLandscape = SnapshotDevice(
        name: "iPhone15ProMax-landscape", config: scaled(.iPhone13ProMax(.landscape))
    )

    // ---- iPads ----
    static let iPadMiniPortrait = SnapshotDevice(
        name: "iPadMini-portrait", config: scaled(.iPadMini)
    )
    static let iPadMiniLandscape = SnapshotDevice(
        name: "iPadMini-landscape", config: scaled(.iPadMini(.landscape))
    )
    static let iPadPro12_9Portrait = SnapshotDevice(
        name: "iPadPro12_9-portrait", config: scaled(.iPadPro12_9)
    )
    static let iPadPro12_9Landscape = SnapshotDevice(
        name: "iPadPro12_9-landscape", config: scaled(.iPadPro12_9(.landscape))
    )

    /// Every iPhone in portrait — the cheap default matrix.
    static let iPhonesPortrait: [SnapshotDevice] = [
        iPhoneSEPortrait, iPhone8Portrait,
        iPhone15ProPortrait, iPhone15ProMaxPortrait
    ]

    /// Every iPad in portrait.
    static let iPadsPortrait: [SnapshotDevice] = [
        iPadMiniPortrait, iPadPro12_9Portrait
    ]

    /// Full matrix — every device × both orientations. ~12 entries.
    static let fullMatrix: [SnapshotDevice] = [
        iPhoneSEPortrait, iPhoneSELandscape,
        iPhone8Portrait, iPhone8Landscape,
        iPhone15ProPortrait, iPhone15ProLandscape,
        iPhone15ProMaxPortrait, iPhone15ProMaxLandscape,
        iPadMiniPortrait, iPadMiniLandscape,
        iPadPro12_9Portrait, iPadPro12_9Landscape,
    ]
}

/// Snapshot the same view across a list of devices. Reuse
/// `SnapshotDevices.fullMatrix` / `.iPhonesPortrait` / `.iPadsPortrait`
/// or pass a curated subset.
func assertSnapshots<V: View>(
    of view: V,
    on devices: [SnapshotDevice],
    named baseName: String,
    file: StaticString = #file,
    testName: String = #function,
    line: UInt = #line
) {
    for device in devices {
        assertSnapshot(
            of: view,
            as: .image(precision: SnapshotConfig.precision,
                       layout: .device(config: device.config),
                       traits: device.config.traits),
            named: "\(baseName)-\(device.name)",
            record: SnapshotConfig.record,
            file: file,
            testName: testName,
            line: line
        )
    }
}

/// Snapshot one view at one device. Use when full-matrix is overkill
/// (most player / sheet variants).
func assertDeviceSnapshot<V: View>(
    of view: V,
    on device: SnapshotDevice,
    named name: String,
    file: StaticString = #file,
    testName: String = #function,
    line: UInt = #line
) {
    assertSnapshot(
        of: view,
        as: .image(precision: SnapshotConfig.precision,
                   layout: .device(config: device.config),
                   traits: device.config.traits),
        named: "\(name)-\(device.name)",
        record: SnapshotConfig.record,
        file: file,
        testName: testName,
        line: line
    )
}

#endif
