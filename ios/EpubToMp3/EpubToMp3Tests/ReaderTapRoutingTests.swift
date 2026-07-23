import XCTest

final class ReaderTapRoutingTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3")
            .appendingPathComponent(relativePath))
    }

    func testPaginatedReaderUsesOneNativeTapRoute() throws {
        let reader = try source("Features/Reader/Views/ReaderView.swift")
        let attributed = try source("Features/Reader/Views/AttributedPageView.swift")
        let pageCurl = try source("Features/Reader/Views/TextKitPageView.swift")

        XCTAssertFalse(pageCurl.contains("textView.addGestureRecognizer(tap)"),
                       "page-curl must have one tap owner, not a second UITextView tap recognizer")
        XCTAssertTrue(pageCurl.contains("pvc.view.addGestureRecognizer(tap)"),
                      "the PVC tap recognizer must remain the page-curl tap owner")

        XCTAssertFalse(reader.contains(".overlay(tapZones("),
                       "paginated pages must not install a second tap recognizer overlay")
        XCTAssertTrue(reader.contains("onZoneTap: enableReaderGestures ? onZoneTap : nil"),
                      "page taps must reach the native TextKit view")
        XCTAssertTrue(attributed.contains("tv.isSelectable = true"),
                      "TextKit scroll/page surfaces must allow UIKit link interaction")
        XCTAssertTrue(pageCurl.contains("tv.isSelectable = true"),
                      "page-curl text surfaces must allow UIKit link interaction")
        XCTAssertTrue(reader.contains("onCenterTap?()"),
                      "ReaderView must route non-link taps to chrome toggle")
    }

    func testPageCurlHasExactlyOneTapOwnerAndItTogglesChromeOnce() throws {
        let textKit = try source("Features/Reader/Views/TextKitPageView.swift")
        let tapRecognizerCount = textKit.components(separatedBy: "UITapGestureRecognizer(").count - 1

        XCTAssertEqual(tapRecognizerCount, 1,
                       "page-curl must have one native tap owner; duplicate PVC and UITextView recognizers toggle twice")
        XCTAssertFalse(textKit.contains("tap.name = \"reader.page.tap\""),
                       "the UITextView must not install a second page tap recognizer")
        XCTAssertTrue(textKit.contains("func handleTap(_ gesture: UITapGestureRecognizer)"),
                      "the single page-curl tap owner must be the PVC coordinator")
        XCTAssertTrue(textKit.contains("parent.onCenterTap?()"),
                      "a non-link physical tap must emit one semantic chrome toggle")
    }

    func testBookAwareScrollSimpleTapsDoNotNavigateChapters() throws {
        let reader = try source("Features/Reader/Views/ReaderView.swift")
        XCTAssertFalse(reader.contains("case .left:\n                        retreatChapter(chapters: chapters)\n                    case .center:\n                        onCenterTap?()\n                    case .right:\n                        advanceChapter(chapters: chapters)"),
                       "book-aware scroll taps must toggle chrome in every zone; chapter navigation belongs to swipes")
    }

    func testReaderActionsHaveStableAccessibilityContractsInBothHosts() throws {
        let dialog = try source("Features/Playback/Views/PlayDivergenceDialog.swift")
        let instantReader = try source("Features/Reader/Views/InstantReaderView.swift")
        let playerReader = try source("Features/Reader/Views/PlayerReaderView.swift")

        XCTAssertTrue(dialog.contains("accessibilityIdentifier(\"reader.divergenceDialog\")"),
                      "the divergence chooser needs a stable accessibility identifier")
        XCTAssertTrue(instantReader.contains("accessibilityIdentifier(\"reader.divergenceDialog\")"),
                      "InstantReaderView must expose the divergence dialog host")
        XCTAssertTrue(playerReader.contains("accessibilityIdentifier(\"reader.divergenceDialog\")"),
                      "PlayerReaderView must expose the divergence dialog host")
        XCTAssertTrue(dialog.contains("accessibilityIdentifier(\"reader.divergence.fromCurrentPage\")"),
                      "the canonical current-page action needs a stable identifier")
        XCTAssertTrue(instantReader.contains("accessibilityIdentifier(\"reader.playFromHere\")"),
                      "InstantReaderView must expose the visible Tocar daqui action")
        XCTAssertTrue(playerReader.contains("accessibilityIdentifier(\"reader.playFromHere\")"),
                      "PlayerReaderView must expose the visible Tocar daqui action")
    }

    func testPlayFromHereRoutesThroughReaderAnchorInBothHosts() throws {
        let instantReader = try source("Features/Reader/Views/InstantReaderView.swift")
        let playerReader = try source("Features/Reader/Views/PlayerReaderView.swift")

        XCTAssertTrue(instantReader.contains("startFromReaderPage("),
                      "InstantReaderView must route Tocar daqui through the reader anchor API")
        XCTAssertTrue(playerReader.contains("startFromReaderPage("),
                      "PlayerReaderView must route Tocar daqui through the reader anchor API")
    }

    func testTapTransitionDebounceIsDiagnosable() throws {
        let reader = try source("Features/Reader/Views/ReaderView.swift")
        let pageCurl = try source("Features/Reader/Views/TextKitPageView.swift")

        XCTAssertTrue(reader.contains("FlickerProbe.shared.log(\"Reader.tap.ignored.transition"),
                      "ReaderView must log taps ignored during a page transition")
        XCTAssertTrue(pageCurl.contains("FlickerProbe.shared.log(\"TextKit.tap.ignored.transition"),
                      "page-curl must log taps ignored during a transition")
    }

    func testChromeAndSelectionOverlaysDoNotOwnTextSurfaceTouches() throws {
        let reader = try source("Features/Reader/Views/ReaderView.swift")
        let instantReader = try source("Features/Reader/Views/InstantReaderView.swift")

        XCTAssertTrue(reader.contains(".allowsHitTesting(false)"),
                      "non-action reader overlays must not block the text surface")
        XCTAssertTrue(instantReader.contains(".allowsHitTesting(floaterSentence != nil)"),
                      "the selection floater must only receive touches while visible")
    }

    func testChromeVisibilityModifierUsesVisibleStateForSystemBars() throws {
        let instantReader = try source("Features/Reader/Views/InstantReaderView.swift")
        let modifier = try XCTUnwrap(
            instantReader.range(of: "struct ChromeVisibilityModifier")
                .map { instantReader[$0.lowerBound...] }
        )

        XCTAssertTrue(modifier.contains(".toolbar(visible ? .visible : .hidden, for: .tabBar)"),
                      "the tab bar must follow the same reader chrome state")
        XCTAssertTrue(modifier.contains("TabBarVisibilityController(visible: visible)"),
                      "the iOS 15 fallback must propagate visible instead of always hiding the tab bar")
    }
}
