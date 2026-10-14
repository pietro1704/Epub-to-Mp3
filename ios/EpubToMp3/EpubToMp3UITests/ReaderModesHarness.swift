import XCTest

@MainActor
final class ReaderModesHarness {
    enum Source {
        case fixture
        case seededLOTR
    }

    struct LaunchConfiguration {
        let source: Source
        let layout: String
        let smallFont: Bool
        let chromeToggleEnabled: Bool
        let paginationProbeEnabled: Bool
        let flickerProbeEnabled: Bool
        let showsPageTurnOverlay: Bool
        let additionalArguments: [String]

        init(
            source: Source,
            layout: String,
            smallFont: Bool,
            chromeToggleEnabled: Bool,
            paginationProbeEnabled: Bool,
            flickerProbeEnabled: Bool = false,
            showsPageTurnOverlay: Bool = false,
            additionalArguments: [String] = []
        ) {
            self.source = source
            self.layout = layout
            self.smallFont = smallFont
            self.chromeToggleEnabled = chromeToggleEnabled
            self.paginationProbeEnabled = paginationProbeEnabled
            self.flickerProbeEnabled = flickerProbeEnabled
            self.showsPageTurnOverlay = showsPageTurnOverlay
            self.additionalArguments = additionalArguments
        }

        static let paginatedFixture = LaunchConfiguration(
            source: .fixture,
            layout: "paginated",
            smallFont: false,
            chromeToggleEnabled: true,
            paginationProbeEnabled: true
        )

        static let paginatedNativeLOTR = LaunchConfiguration(
            source: .seededLOTR,
            layout: "paginated",
            smallFont: false,
            chromeToggleEnabled: true,
            paginationProbeEnabled: true
        )
    }

    struct PaginationMetrics {
        let values: [String: Int]

        var page: Int? { values["page"] }
        var total: Int? { values["total"] }
        var clippedLineCount: Int? { values["clippedLineCount"] }
    }

    let app: XCUIApplication
    private var activeReaderPage: Int?
    private var activeReaderPageCount: Int?

    init(app: XCUIApplication = XCUIApplication()) {
        self.app = app
    }

    @discardableResult
    func launch(_ configuration: LaunchConfiguration = .paginatedFixture) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        switch configuration.source {
        case .fixture:
            app.launchArguments += ["-uiTestFixture", "-uiTestResetReaderPosition"]
        case .seededLOTR:
            // The native regression must exercise the staged EPUB itself.
            // `-uiTestFixture` intentionally replaces reader content with a
            // synthetic payload, so it must not be present on this path.
            app.launchArguments += ["-uiTestResetReaderPosition", "-developmentSeedBook", "-uiTestPlaybackFixture"]
        }
        app.launchArguments += ["-uiTestReaderLayout", configuration.layout]
        if configuration.chromeToggleEnabled {
            app.launchArguments += ["-uiTestChromeToggle"]
        }
        if configuration.paginationProbeEnabled {
            app.launchArguments += ["-uiTestPaginationProbe"]
        }
        if configuration.flickerProbeEnabled {
            app.launchArguments += ["-uiTestFlickerProbe"]
        }
        if !configuration.showsPageTurnOverlay {
            app.launchArguments += ["-uiTestNoPageTurnOverlay"]
        }
        if configuration.smallFont {
            app.launchArguments += ["-uiTestReaderFontSize", "0", "-uiTestReaderOverrideFontSize"]
        }
        app.launchArguments += configuration.additionalArguments
        app.launch()
        return app
    }

    func openBook(titleContaining title: String? = nil, timeout: TimeInterval = 20) throws {
        var books = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        )
        if let title {
            books = books.matching(NSPredicate(format: "label CONTAINS[c] %@", title))
        }
        let firstBook = books.firstMatch
        guard firstBook.waitForExistence(timeout: timeout) else {
            throw XCTSkip("No matching book is available for the reader test.")
        }
        if !firstBook.isHittable {
            // A native collection-cell accessibility element can be exposed
            // before XCTest refreshes its hittability flag. Tapping its
            // resolved centre exercises the same visible card without
            // replacing a real EPUB test with the synthetic fixture.
            firstBook.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            firstBook.tap()
        }
        XCTAssertTrue(
            app.buttons["reader.search"].firstMatch.waitForExistence(timeout: timeout),
            "The selected book must open in the native reader."
        )
    }

    func toggleChrome() {
        let testToggle = app.buttons.matching(identifier: "reader.chrome.toggle")
            .allElementsBoundByIndex.first(where: \.isHittable)
        if let testToggle {
            testToggle.tap()
            return
        }
        let viewport = app.scrollViews.matching(identifier: "reader.viewport")
            .allElementsBoundByIndex.first(where: \.isHittable) ?? app.scrollViews["reader.viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 5), "The reader viewport must be available.")
        // Stay in the central reader column but below the typical EPUB
        // navigation/footnote link cluster. A link intentionally wins over
        // chrome, so the automation must exercise a normal reading tap.
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78)).tap()
    }

    func toggleChromeAndSettle(visible: Bool, timeout: TimeInterval = 3) {
        guard chromeIsVisible != visible else { return }
        toggleChrome()
        XCTAssertTrue(
            waitUntil(timeout: timeout) {
                guard self.chromeIsVisible == visible,
                      let metrics = self.paginationMetrics else { return false }
                return metrics.values["chromeHidden"] == (visible ? 0 : 1)
            },
            "The reader chrome and matching final pagination probe must settle to visible=\(visible); metrics=\(paginationMetrics?.values ?? [:]); cachedPage=\(String(describing: activeReaderPage))/\(String(describing: activeReaderPageCount))."
        )
    }

    func turnPage(forward: Bool, timeout: TimeInterval = 3) {
        let button = app.buttons[forward ? "reader.pageTurn.right" : "reader.pageTurn.left"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: timeout), "The page-turn control must be available.")
        let previousPage = paginationMetrics?.page
        button.tap()
        if let previousPage {
            XCTAssertTrue(
                waitUntil(timeout: timeout) { self.paginationMetrics?.page != previousPage },
                "The page indicator must change after an explicit page turn."
            )
        }
    }

    var chromeIsVisible: Bool {
        app.buttons.matching(identifier: "reader.search").allElementsBoundByIndex.contains(where: \.isHittable)
            || app.buttons.matching(identifier: "reader.close").allElementsBoundByIndex.contains(where: \.isHittable)
    }

    func paginationProbe(for pageCount: Int? = nil) -> XCUIElement? {
        let probes = app.staticTexts.matching(identifier: "reader.paginationProbe")
        let visibleIndicator = app.descendants(matching: .any)
            .matching(identifier: "reader.pageIndicator")
            .allElementsBoundByIndex.first(where: \.isHittable)
        var visiblePage: Int?
        var visiblePageCount: Int?
        if let visibleIndicator {
            let indicatorText = (visibleIndicator.value as? String) ?? visibleIndicator.label
            let indicatorNumbers = indicatorText
                .components(separatedBy: CharacterSet.decimalDigits.inverted)
                .compactMap(Int.init)
            visiblePage = indicatorNumbers.first
            visiblePageCount = indicatorNumbers.last
            activeReaderPage = indicatorNumbers.first
            activeReaderPageCount = indicatorNumbers.last
        }
        let candidates = probes.allElementsBoundByIndex.filter { probe in
            let values = Self.integerMetrics(from: probe.label)
            return values["total"] != nil
                && (pageCount == nil || values["total"] == pageCount)
                && (visiblePageCount == nil || values["total"] == visiblePageCount)
        }
        return candidates.min { left, right in
            guard let visiblePage else { return false }
            let leftPage = Self.integerMetrics(from: left.label)["page"] ?? Int.max
            let rightPage = Self.integerMetrics(from: right.label)["page"] ?? Int.max
            return abs(leftPage - visiblePage) < abs(rightPage - visiblePage)
        }
    }

    var paginationMetrics: PaginationMetrics? {
        guard let probe = paginationProbe() else { return nil }
        let values = Self.integerMetrics(from: probe.label)
        return PaginationMetrics(values: values)
    }

    private static func integerMetrics(from label: String) -> [String: Int] {
        let pairs: [(String, Int)] = label.split(separator: ";").compactMap { item in
            let pair = item.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let value = Int(pair[1]) else { return nil }
            return (String(pair[0]), value)
        }
        return Dictionary(uniqueKeysWithValues: pairs)
    }

    func assertNoClippedLines(
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let metrics = paginationMetrics,
              let firstY = metrics.values["firstCompleteY"],
              let lastY = metrics.values["lastCompleteY"],
              let clippedLineCount = metrics.clippedLineCount,
              let viewportTop = metrics.values["viewportTop"],
              let viewportBottom = metrics.values["viewportBottom"] else {
            let probes = app.staticTexts.matching(identifier: "reader.paginationProbe").allElementsBoundByIndex
                .map(\.label).joined(separator: " | ")
            return XCTFail("\(scenario): pagination probe is incomplete: \(paginationMetrics?.values ?? [:]); cachedPage=\(String(describing: activeReaderPage))/\(String(describing: activeReaderPageCount)); probes=\(probes)", file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(
            firstY,
            viewportTop - 1,
            "\(scenario): the first visible line is cut above the viewport (\(metrics.values))",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            lastY,
            viewportBottom + 1,
            "\(scenario): the last visible line is cut below the viewport (\(metrics.values))",
            file: file,
            line: line
        )
        XCTAssertEqual(
            clippedLineCount,
            0,
            "\(scenario): a TextKit line fragment is cut by the viewport (\(metrics.values))",
            file: file,
            line: line
        )
    }
}
