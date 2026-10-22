import XCTest
@testable import EpubToMp3
#if os(iOS)
import UIKit
#endif

@MainActor
final class ConversionSettingsAccessibilityTests: XCTestCase {
    func testReaderSettingsRefreshNotifiesPresenterAndRetainsAccessibleControls() throws {
#if os(iOS)
        let suite = "reader-settings-accessibility-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = ReaderSettingsScreenController(settings: AppSettings(defaults: defaults))
        controller.loadViewIfNeeded()
        var changes = 0
        controller.onChange = { changes += 1 }
        controller.refresh()
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(controller.tableView.accessibilityLabel, L10n.string("readerSettings.title"))
        XCTAssertEqual(controller.tableView.rowHeight, UITableView.automaticDimension)
        XCTAssertEqual(controller.navigationItem.rightBarButtonItem?.title, L10n.string("readerSettings.done"))
        XCTAssertNotNil(controller.navigationItem.rightBarButtonItem?.action)
#else
        throw XCTSkip("UIKit accessibility requires the iOS runtime; Simulator execution remains quarantined.")
#endif
    }
    func testReaderSettingsChoicesExposeCurrentLabelsValuesAndHints() throws {
#if os(iOS)
        let suite = "settings-choice-hints-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let table = UITableView(frame: .zero, style: .insetGrouped)
        table.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        let rows = ReaderSettingsRows(tableView: table, settings: settings)
        let choice = rows.cell(for: IndexPath(row: 1, section: 0))
        XCTAssertEqual(choice.accessibilityLabel, L10n.string("settings.font"))
        XCTAssertEqual(choice.accessibilityValue, settings.readerFontFamily.displayName)
        XCTAssertEqual(choice.accessibilityHint, L10n.string("settings.openOptionHint"))
        let toggle = rows.cell(for: IndexPath(row: 6, section: 0))
        XCTAssertEqual(toggle.accessibilityHint, L10n.string("settings.autoScrollHint"))
        XCTAssertNil(toggle.accessibilityValue, "Reused cells must not announce a stale selection value.")
#else
        throw XCTSkip("UIKit accessibility requires iOS; Simulator execution remains quarantined.")
#endif
    }

    func testJobsHistorySuccessEmptyAndFailureRetainAccessibleRefreshAndSafeArea() async throws {
#if os(iOS)
        let suite = "jobs-accessibility-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let record = try JSONDecoder().decode(SessionRecord.self, from: Data(
            #"{"timestamp":"fixture-time","book_title":"History fixture","job_id":"history-owned"}"#.utf8))
        for scenario in 0..<3 {
            let controller = JobsListScreenController(settings: AppSettings(defaults: defaults),
                library: LibraryStore(defaults: defaults), player: player, playbackClock: PlaybackClock(),
                historyLoader: {
                    if scenario == 2 { throw NSError(domain: "FixtureHistory", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Isolated history failed"]) }
                    return scenario == 0 ? [record] : []
                })
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
            window.rootViewController = controller
            window.isHidden = false
            defer { window.isHidden = true; window.rootViewController = nil }
            controller.view.layoutIfNeeded()
            func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
            let expectedMessage = scenario == 1 ? L10n.string("jobs.noConversionsDescription") : "Isolated history failed"
            for _ in 0..<100 {
                let views = descendants(controller.view)
                if scenario == 0, let table = views.compactMap({ $0 as? UITableView }).first,
                   table.numberOfRows(inSection: 0) == 1 { break }
                if scenario != 0, views.compactMap({ $0 as? UILabel }).contains(where: { $0.text == expectedMessage && !$0.isHidden }) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let refresh = try XCTUnwrap(controller.navigationItem.rightBarButtonItem)
            XCTAssertEqual(refresh.accessibilityLabel, L10n.string("jobs.refresh"))
            XCTAssertEqual(refresh.accessibilityHint, L10n.string("jobs.refreshHint"))
            XCTAssertNotNil(refresh.action)
            let table = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UITableView }.first)
            let frame = table.convert(table.bounds, to: controller.view)
            XCTAssertEqual(frame.maxY, controller.view.safeAreaLayoutGuide.layoutFrame.maxY, accuracy: 0.5)
            if scenario == 0 {
                XCTAssertFalse(table.isHidden)
                XCTAssertEqual(table.numberOfRows(inSection: 0), 1)
                let cell = try XCTUnwrap(table.dataSource?.tableView(table, cellForRowAt: IndexPath(row: 0, section: 0)))
                XCTAssertEqual(cell.accessibilityLabel, "History fixture")
                XCTAssertEqual(cell.accessibilityHint, L10n.string("jobs.openJobHint"))
            } else {
                XCTAssertTrue(table.isHidden)
                XCTAssertTrue(descendants(controller.view).compactMap { $0 as? UILabel }.contains { $0.text == expectedMessage && !$0.isHidden })
            }
        }
#else
        throw XCTSkip("UIKit history presentation requires iOS; Simulator execution remains quarantined.")
#endif
    }

}
