#if os(iOS)
import Combine
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class ManualConversionScreenTests: XCTestCase {
    private let action = IndexPath(row: 0, section: 5)

    private func makeScreen(_ session: ManualConversionSession) throws
        -> (ConvertScreenController, UINavigationController, AudioPlayer) {
        let suite = "manual-screen-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let settings = AppSettings(defaults: defaults)
        settings.backendURL = ""
        let controller = ConvertScreenController(settings: settings, library: LibraryStore(defaults: defaults),
            player: player, playbackClock: player.playbackClock,
            preselectedFileURL: URL(fileURLWithPath: "/fixture-only/input.epub"),
            viewModel: ConvertViewModel(session: session))
        let navigation = UINavigationController(rootViewController: controller)
        navigation.loadViewIfNeeded()
        controller.loadViewIfNeeded()
        controller.tableView.reloadData()
        return (controller, navigation, player)
    }

    private func flushMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func result(_ id: String) -> RustConversionCoordinator.Result {
        .init(jobID: id, manifestJSON: Data("""
        {"manifest":{"jobId":"\(id)","title":"Manual fixture","author":"Author","chapters":[]}}
        """.utf8), outputDirectory: URL(fileURLWithPath: "/fixture-only/output"))
    }

    func testResultMetadataClearsAccessoriesReusedFromChaptersAndActions() throws {
        let session = ManualConversionSession(executor: { _, id, _, _, _, _, _ in self.result(id) })
        let (_, navigation, player) = try makeScreen(session)
        let suite = "result-cell-reuse-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = try JSONDecoder().decode(JobSnapshot.self, from: Data("""
        {"jobId":"result-cell-reuse","state":"completed","bookTitle":"Fixture book",
         "chapterProgress":[{"index":0,"name":"Fixture chapter","status":"completed",
         "downloadUrl":"file:///fixture-only/chapter.mp3"}]}
        """.utf8))
        let detail = JobDetailScreenController(jobId: snapshot.jobId, settings: AppSettings(defaults: defaults),
            library: LibraryStore(defaults: defaults), player: player, playbackClock: player.playbackClock,
            localSnapshot: snapshot)
        detail.loadViewIfNeeded()
        let table = ResultCellReuseTable(frame: .zero, style: .plain)
        detail.tableView = table
        detail.viewWillAppear(false)
        XCTAssertEqual(detail.numberOfSections(in: table), 3)
        for row in 0..<3 {
            for (section, accessory) in [(1, UITableViewCell.AccessoryType.checkmark), (2, .disclosureIndicator)] {
                let previous = detail.tableView(table, cellForRowAt: IndexPath(row: 0, section: section))
                XCTAssertEqual(previous.accessoryType, accessory)
                let metadata = detail.tableView(table, cellForRowAt: IndexPath(row: row, section: 0))
                XCTAssertTrue(metadata === previous, "Exercise the same UIKit cell after another row role.")
                XCTAssertEqual(metadata.accessoryType, .none, "Read-only metadata must not inherit another row's accessory.")
                XCTAssertEqual(metadata.selectionStyle, .none)
            }
        }
        XCTAssertNil(player.snapshot)
        XCTAssertFalse(player.isPlaying)
        withExtendedLifetime(navigation) {}
    }

    func testTableObservesInFlightProgressAndExposesCancelWithoutWaitingForCompletion() async throws {
        let gate = ManualConversionGate()
        defer { gate.release() }
        let entered = expectation(description: "Manual executor has progress")
        let session = ManualConversionSession(executor: { _, id, _, _, _, update, _ in
            update?(.init(jobId: id, state: "running", chapterIndex: 0, chaptersTotal: 2,
                          chaptersCompleted: 1, percent: 50, engine: "piper", message: "Fixture"))
            entered.fulfill()
            await gate.wait()
            return self.result(id)
        })
        let (controller, navigation, player) = try makeScreen(session)
        let cancelled = expectation(description: "Cancellation completed")
        let observer = session.$phase.filter { $0 == .cancelled }.first().sink { _ in cancelled.fulfill() }
        defer { observer.cancel() }
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 5), 1)
        controller.tableView(controller.tableView, didSelectRowAt: action)
        await fulfillment(of: [entered], timeout: 1)
        await flushMainQueue()
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 5), 2)
        let status = controller.tableView(controller.tableView, cellForRowAt: action)
        XCTAssertEqual(status.accessibilityLabel, L10n.string("convert.progressPercent", 50))
        XCTAssertNotNil(status.accessoryView)
        let cancelIndex = IndexPath(row: 1, section: 5)
        let cancel = controller.tableView(controller.tableView, cellForRowAt: cancelIndex)
        XCTAssertEqual(cancel.accessibilityIdentifier, "convert.cancel")
        controller.tableView(controller.tableView, didSelectRowAt: cancelIndex)
        XCTAssertEqual(session.phase, .cancelling)
        gate.release()
        await fulfillment(of: [cancelled], timeout: 1)
        await flushMainQueue()
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 5), 1)
        let restored = controller.tableView(controller.tableView, cellForRowAt: action)
        XCTAssertNil(restored.accessoryView)
        XCTAssertEqual(restored.accessibilityLabel, L10n.string("convert.startConversion"))
        XCTAssertNil(player.snapshot)
        XCTAssertFalse(player.isPlaying)
        withExtendedLifetime(navigation) {}
    }

    func testProviderFailureRestoresSubmitAndDisplaysAnError() async throws {
        let failed = expectation(description: "Provider failure published")
        let session = ManualConversionSession(executor: { _, _, _, _, _, _, _ in
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Provider failed"])
        })
        let observer = session.$phase.filter { $0 == .failed }.first().sink { _ in failed.fulfill() }
        defer { observer.cancel() }
        let (controller, navigation, _) = try makeScreen(session)
        controller.tableView(controller.tableView, didSelectRowAt: action)
        await fulfillment(of: [failed], timeout: 1)
        await flushMainQueue()
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 5), 1)
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 4), 1)
        XCTAssertNil(controller.tableView(controller.tableView, cellForRowAt: action).accessoryView)
        let error = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 0, section: 4))
        XCTAssertEqual((error.contentConfiguration as? UIListContentConfiguration)?.text, "Provider failed")
        withExtendedLifetime(navigation) {}
    }

    func testCompletedResultOpensLocallyWithoutBackendOrPlaybackTakeover() async throws {
        let completed = expectation(description: "Local result published")
        let session = ManualConversionSession(executor: { _, id, _, _, _, _, _ in self.result(id) })
        let observer = session.$phase.filter { $0 == .completed }.first().sink { _ in completed.fulfill() }
        defer { observer.cancel() }
        let (controller, navigation, player) = try makeScreen(session)
        controller.tableView(controller.tableView, didSelectRowAt: action)
        await fulfillment(of: [completed], timeout: 1)
        await flushMainQueue()
        controller.tableView(controller.tableView, didSelectRowAt: IndexPath(row: 1, section: 4))
        let detail = try XCTUnwrap(navigation.topViewController as? JobDetailScreenController)
        detail.loadViewIfNeeded()
        detail.viewWillAppear(false)
        let book = detail.tableView(detail.tableView, cellForRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual((book.contentConfiguration as? UIListContentConfiguration)?.text, L10n.string("jobDetail.book"))
        XCTAssertEqual((book.contentConfiguration as? UIListContentConfiguration)?.secondaryText, "Manual fixture")
        XCTAssertNil(player.snapshot)
        XCTAssertFalse(player.isPlaying)
    }
}

@MainActor
private final class ResultCellReuseTable: UITableView {
    private let recycledCell = UITableViewCell(style: .subtitle, reuseIdentifier: "Subtitle")

    override func dequeueReusableCell(withIdentifier identifier: String, for indexPath: IndexPath) -> UITableViewCell {
        recycledCell
    }
}

#endif
