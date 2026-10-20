import XCTest
#if os(macOS)
import AppKit
#endif
@testable import EpubToMp3

final class AppWindowConfigurationTests: XCTestCase {
    #if os(macOS)
    func testMacOSDefaultWindowSizeLeavesRoomForSplitView() {
        let minimum = EpubToMp3WindowConfiguration.macOSMinimumSize
        let size = EpubToMp3WindowConfiguration.macOSDefaultSize

        XCTAssertGreaterThanOrEqual(minimum.width, 1000)
        XCTAssertGreaterThanOrEqual(minimum.height, 700)
        XCTAssertGreaterThanOrEqual(size.width, 1000)
        XCTAssertGreaterThanOrEqual(size.height, 700)
    }

    func testMacOSNativeDelegateOwnsTheWindow() throws {
        let source = try readSourceFileIfAvailable(
            at: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/App/EpubToMp3App.swift")
        )
        XCTAssertTrue(source.contains("NSApplicationDelegate"))
        XCTAssertTrue(source.contains("contentViewController = root"))
        XCTAssertFalse(source.contains("WindowGroup"))
    }

    @MainActor
    func testProgrammaticWindowUsesExplicitGeometryWithoutArchivedRestoration() {
        let window = EpubToMp3WindowConfiguration.makeMacOSWindow()
        XCTAssertFalse(window.isRestorable)
        XCTAssertNil(window.restorationClass)
        XCTAssertEqual(window.minSize, EpubToMp3WindowConfiguration.macOSMinimumSize)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size,
                       EpubToMp3WindowConfiguration.macOSDefaultSize)
    }

    @MainActor
    func testDelegateRejectsAutomaticWindowArchivesWhileSupportingSecureState() throws {
        let suite = "window-restoration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = EpubToMp3App(library: LibraryStore(defaults: defaults, defaultsKey: "library"))
        XCTAssertTrue(app.applicationSupportsSecureRestorableState(NSApplication.shared))
        XCTAssertFalse(app.applicationShouldSaveSecureApplicationState(NSApplication.shared))
        XCTAssertFalse(app.applicationShouldRestoreSecureApplicationState(NSApplication.shared))
    }
    #endif
}
