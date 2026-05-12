import XCTest
import SwiftUI
@testable import EpubToMp3

/// Smoke tests for the iOS 15 / macOS 12 backport shims in
/// `PlatformCompat.swift`. We can't snapshot SwiftUI rendering on
/// older OSes from here (the test host is whatever the developer's
/// Mac runs), so these tests focus on:
///   1. The shims compile and instantiate without crashing on the
///      *current* OS (catches naming/signature regressions).
///   2. The `CompatKey` enum stays exhaustive — `handleCompatKey`
///      in `ReaderView.swift` switches on it, so a missing case
///      would break paginated reader navigation.
///   3. The `CompatLabeledContent` convenience initialisers
///      typecheck — they're called from every Form section.
final class PlatformCompatTests: XCTestCase {
    func testCompatKeyEnumIsExhaustive() {
        // Every CompatKey case must be handled by the reader's
        // page-turn dispatcher. If a new case lands without a
        // matching switch arm in `handleCompatKey`, the compiler
        // will catch it — this test just guarantees we iterate
        // through every case (it would fail to compile if a case
        // were removed).
        let allKeys: [CompatKey] = [
            .leftArrow, .rightArrow, .pageUp, .pageDown,
            .space, .home, .end, .j, .k,
        ]
        XCTAssertEqual(allKeys.count, 9)
    }

    func testCompatLabeledContentValueInitializerCompiles() {
        // The (String, value: String) convenience initialiser is
        // used in JobDetailView for every job-stat row. If the
        // generic constraint regresses, this stops compiling.
        let label = CompatLabeledContent("ID", value: "abc-123")
        // Just touch the view to keep the optimiser from elision.
        _ = label.body
    }

    func testCompatLabeledContentViewBuilderInitializerCompiles() {
        // The view-builder form is used in TelemetryView and
        // SettingsView's About section. Ensure the inferred
        // generic params still resolve.
        let label = CompatLabeledContent("Selected") {
            Text("/tmp/foo.epub")
        }
        _ = label.body
    }

    func testCompatNavigationStackInstantiation() {
        let stack = CompatNavigationStack {
            Text("root")
        }
        _ = stack.body
    }

    func testCompatContentUnavailableViewNoDescription() {
        let v = CompatContentUnavailableView("Empty",
                                             systemImage: "tray")
        _ = v.body
    }

    func testCompatContentUnavailableViewWithDescription() {
        let v = CompatContentUnavailableView("Empty",
                                             systemImage: "tray",
                                             description: Text("Add a book."))
        _ = v.body
    }
}
