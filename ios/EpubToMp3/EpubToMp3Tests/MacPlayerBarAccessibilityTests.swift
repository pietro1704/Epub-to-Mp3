#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MacPlayerBarAccessibilityTests: XCTestCase {
    func testVisiblePlayerRemainsReachableAcrossLibraryAndSettings() async throws {
        let fixture = try PlayerAccessibilityFixture(hasSnapshot: true)
        defer { fixture.cleanup() }
        try await fixture.activateIfRequested()
        let bar = try fixture.bar()
        XCTAssertFalse(bar.isHidden)
        try fixture.assertCurrentAccessibleContent(includes: bar)
        let previous = fixture.detail.accessibilityChildren()?.compactMap { $0 as? NSView }
            .first { $0 !== bar }
        fixture.root.showSettings(nil)
        fixture.window.layoutIfNeeded()
        try fixture.assertCurrentAccessibleContent(includes: bar)
        XCTAssertFalse((fixture.detail.accessibilityChildren() ?? []).contains {
            ($0 as? NSView) === previous
        }, "Retired content must not remain in the accessibility tree")
        fixture.root.focusLibrarySearch(nil)
        fixture.window.layoutIfNeeded()
        try fixture.assertCurrentAccessibleContent(includes: bar)
        try fixture.captureIfRequested(name: "visible-persistent-player-accessibility", test: self)
    }

    func testReaderErrorReplacesContentWithoutLosingPersistentPlayer() async throws {
        let fixture = try PlayerAccessibilityFixture(hasSnapshot: true)
        defer { fixture.cleanup() }
        let bar = try fixture.bar()
        fixture.root.showReader(bookID: "missing-accessibility-book-\(UUID().uuidString)")
        await Task.yield()
        fixture.window.layoutIfNeeded()
        try fixture.assertCurrentAccessibleContent(includes: bar)
        fixture.root.focusLibrarySearch(nil)
        fixture.window.layoutIfNeeded()
        try fixture.assertCurrentAccessibleContent(includes: bar)
    }

    func testEmptyLibraryDoesNotExposeCollapsedPlayer() throws {
        let fixture = try PlayerAccessibilityFixture(hasSnapshot: false)
        defer { fixture.cleanup() }
        let bar = try fixture.bar()
        XCTAssertTrue(bar.isHidden)
        XCTAssertFalse((fixture.detail.accessibilityChildren() ?? []).contains { ($0 as? NSView) === bar })
    }
}

@MainActor
private final class PlayerAccessibilityFixture {
    private let suite = "MacPlayerAccessibility.\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let player: AudioPlayer
    private let keys = [ReaderSessionState.currentlyReadingBookIDKey, AudioPlayer.currentBookIDDefaultsKey,
                        AudioPlayer.readerCurrentChapterIndexDefaultsKey, AudioPlayer.readerCurrentPageRatioDefaultsKey,
                        AudioPlayer.readerCurrentSentenceIdDefaultsKey, "readerWarmBookIDs.v1"]
    private let saved: [Any?]
    private let policy: NSApplication.ActivationPolicy
    let root: MacAppKitRootController
    let window: NSWindow
    var detail: NSView { root.splitViewItems[1].viewController.view }

    init(hasSnapshot: Bool) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        if hasSnapshot {
            player.playbackSnapshotChanged(try JSONDecoder().decode(JobSnapshot.self, from:
                Data(#"{"jobId":"accessibility-fixture","state":"failed","bookTitle":"Accessibility fixture","error":"Unavailable fixture voice"}"#.utf8)))
        }
        root = MacAppKitRootController(settings: AppSettings(defaults: defaults),
            library: LibraryStore(defaults: defaults, defaultsKey: "library"), player: player,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            playerPresentation: PlayerPresentation(defaults: defaults))
        policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 700),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = root
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        root.view.layoutSubtreeIfNeeded()
    }

    func bar() throws -> NSView {
        try XCTUnwrap(detail.subviews.first { view in
            Self.descendants(view).contains {
                ($0 as? NSButton)?.action == NSSelectorFromString("togglePlayback")
            }
        })
    }

    func assertCurrentAccessibleContent(includes bar: NSView, file: StaticString = #filePath, line: UInt = #line) throws {
        let children = (detail.accessibilityChildren() ?? []).compactMap { $0 as? NSView }
        XCTAssertEqual(children.count, 2, file: file, line: line)
        XCTAssertEqual(children.filter { $0 === bar }.count, 1,
                       "The explicit accessibility tree must include the persistent player once", file: file, line: line)
        XCTAssertTrue(children.allSatisfy { $0.superview === detail }, file: file, line: line)
        let play = try XCTUnwrap(Self.descendants(bar).compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString("togglePlayback") }, file: file, line: line)
        let cell = try XCTUnwrap(play.cell, file: file, line: line)
        XCTAssertTrue(Self.accessibleElements(detail).contains { ($0 as? NSCell) === cell },
                      "The actual transport cell must be reachable through accessibility children", file: file, line: line)
        XCTAssertEqual(cell.accessibilityRole(), .button, file: file, line: line)
        let label = try XCTUnwrap(cell.accessibilityLabel(), file: file, line: line)
        // AppKit can lowercase the localized SF Symbol label on the cell.
        XCTAssertEqual(label.localizedCaseInsensitiveCompare(L10n.string("player.play")), .orderedSame,
                       file: file, line: line)
    }

    func activateIfRequested() async throws {
        guard ProcessInfo.processInfo.environment["EPUB_MAC_PLAYER_GUI_ACCEPTANCE"] == "1" else { return }
        let activation = NSWorkspace.OpenConfiguration()
        activation.activates = true
        activation.createsNewApplicationInstance = false
        let running = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: activation)
        XCTAssertEqual(running.processIdentifier, ProcessInfo.processInfo.processIdentifier)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, ProcessInfo.processInfo.processIdentifier)
    }

    func captureIfRequested(name: String, test: XCTestCase) throws {
        guard ProcessInfo.processInfo.environment["EPUB_MAC_PLAYER_GUI_ACCEPTANCE"] == "1" else { return }
        let bar = try bar()
        XCTAssertGreaterThan(bar.visibleRect.height, 0)
        let content = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                       uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }

    func cleanup() {
        LocalFulltextCache.cancelPrewarming()
        player.stop()
        window.orderOut(nil); window.contentViewController = nil; window.close()
        for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) }
        defaults.removePersistentDomain(forName: suite)
        NSApp.setActivationPolicy(policy)
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func accessibleElements(_ view: NSView) -> [Any] {
        // AppKit exposes NSButtonCell objects as leaf accessibility elements.
        [view] + (view.accessibilityChildren() ?? []).flatMap { child -> [Any] in
            if let childView = child as? NSView { return accessibleElements(childView) }
            return [child]
        }
    }
}
#endif
