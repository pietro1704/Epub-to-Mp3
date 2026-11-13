import XCTest
@testable import EpubToMp3

final class ReaderToolPreferenceTests: XCTestCase {
    func testRecentToolDefaultsAndPersistsAcrossRelaunch() throws {
        let suite = "RecentTool.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = ReaderToolPreference(defaults: defaults)
        XCTAssertEqual(preference.recent, .appearance)
        preference.recent = .contents
        XCTAssertEqual(ReaderToolPreference(defaults: defaults).recent, .contents)
        defaults.set("removed-tool", forKey: "reader.recentTool.v1")
        XCTAssertEqual(ReaderToolPreference(defaults: defaults).recent, .appearance)
    }
}

#if os(iOS)
import UIKit

@MainActor
final class ReaderToolBarTests: XCTestCase {
    func testExactlyTwoNativeItemsKeepIdentityAfterUsingAnotherTool() throws {
        let suite = "NativeRecentTool.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var performed: [ReaderTool] = []
        let toolbar = ReaderToolBar(defaults: defaults) { performed.append($0) }
        let initial = toolbar.items
        XCTAssertEqual(initial.count, 2)
        XCTAssertEqual(initial[0].accessibilityIdentifier, "reader.more")
        XCTAssertEqual(initial[1].title, "Aa")
        XCTAssertEqual(initial[0].menu?.children.count, ReaderTool.allCases.count)
        toolbar.choose(.search)
        XCTAssertTrue(toolbar.items[0] === initial[0])
        XCTAssertTrue(toolbar.items[1] === initial[1])
        XCTAssertEqual(toolbar.items[1].accessibilityIdentifier, "reader.search")
        XCTAssertEqual(performed, [.search])
        XCTAssertEqual(ReaderToolPreference(defaults: defaults).recent, .search)
    }
}
#endif
