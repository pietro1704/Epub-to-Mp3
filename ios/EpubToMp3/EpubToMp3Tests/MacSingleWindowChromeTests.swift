import XCTest
@testable import EpubToMp3

#if os(macOS)
import AppKit

/// The Mac app has exactly one main window: no native window tabs, no second
/// window from the Dock, and the sidebar toggle lives in the sidebar titlebar.
final class MacSingleWindowChromeTests: XCTestCase {
    private struct ShippingWindowFixture {
        let setup: (root: MacAppKitRootController, window: NSWindow)
        let cleanup: () -> Void
    }

    @MainActor
    private func makeShippingWindow() throws -> ShippingWindowFixture {
        let suite = "single-window.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let keys = [ReaderSessionState.currentlyReadingBookIDKey, AudioPlayer.currentBookIDDefaultsKey, "readerWarmBookIDs.v1"]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let timing = AppStartupTiming(arguments: [])
        let setup = MacApplicationWindowSetup.make(settings: AppSettings(defaults: defaults),
            library: LibraryStore(defaults: defaults, defaultsKey: "library", startupTiming: timing), player: player,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            playerPresentation: PlayerPresentation(defaults: defaults), timing: timing)
        // Keep the fixture alive through cleanup even if production regresses.
        setup.window.isReleasedWhenClosed = false
        setup.window.layoutIfNeeded()
        return ShippingWindowFixture(setup: setup) {
            LocalFulltextCache.cancelPrewarming()
            player.stop()
            setup.window.orderOut(nil); setup.window.contentViewController = nil; setup.window.close()
            for (key, value) in zip(keys, previous) { UserDefaults.standard.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: suite)
            NSApp.setActivationPolicy(policy)
        }
    }

    // MARK: - Sidebar toggle placement

    @MainActor
    func testToolbarPlacesSidebarToggleBeforeSidebarTrackingSeparator() throws {
        let fixture = try makeShippingWindow()
        defer { fixture.cleanup() }
        let (root, window) = fixture.setup
        let toolbar = try XCTUnwrap(window.toolbar)
        let expected: [NSToolbarItem.Identifier] = [
            MacAppKitRootController.sidebarToolbarItemIdentifier, .sidebarTrackingSeparator,
        ]

        XCTAssertEqual(root.toolbarDefaultItemIdentifiers(toolbar), expected)
        let allowed = root.toolbarAllowedItemIdentifiers(toolbar)
        let toggleIndex = try XCTUnwrap(allowed.firstIndex(of: MacAppKitRootController.sidebarToolbarItemIdentifier))
        let separatorIndex = try XCTUnwrap(allowed.firstIndex(of: .sidebarTrackingSeparator))
        XCTAssertLessThan(toggleIndex, separatorIndex)
        XCTAssertEqual(toolbar.items.map(\.itemIdentifier), expected)
        // The tracking separator only splits the titlebar for full-size content windows.
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertTrue(window.contentViewController === root)
        // The usable area below the toolbar keeps the default size.
        let defaultSize = EpubToMp3WindowConfiguration.macOSDefaultSize
        XCTAssertEqual(window.contentLayoutRect.width, defaultSize.width, accuracy: 0.5)
        XCTAssertEqual(window.contentLayoutRect.height, defaultSize.height, accuracy: 0.5)
    }

    @MainActor
    func testSidebarToggleStaysLeadingAndTogglesOnlyNavigationSidebar() throws {
        let fixture = try makeShippingWindow()
        defer { fixture.cleanup() }
        let (root, window) = fixture.setup
        let toolbar = try XCTUnwrap(window.toolbar)
        let toggle = try XCTUnwrap(toolbar.items.first)
        XCTAssertEqual(toggle.itemIdentifier, MacAppKitRootController.sidebarToolbarItemIdentifier)
        XCTAssertEqual(toggle.toolTip, L10n.string("nav.toggleSidebar"))
        XCTAssertEqual(toggle.label, L10n.string("nav.toggleSidebar"))
        XCTAssertEqual(toggle.action, #selector(MacAppKitRootController.toggleNavigationSidebar(_:)))

        XCTAssertTrue(NSApplication.shared.sendAction(toggle.action!, to: toggle.target, from: toggle))
        window.layoutIfNeeded()
        XCTAssertTrue(root.splitViewItems[0].isCollapsed)
        XCTAssertFalse(root.splitViewItems[1].isCollapsed)
        XCTAssertEqual(toolbar.items.first?.itemIdentifier, MacAppKitRootController.sidebarToolbarItemIdentifier,
                       "The toggle must remain the leading item while the sidebar is collapsed.")
        XCTAssertGreaterThan(root.splitViewItems[1].viewController.view.frame.width, 0)

        XCTAssertTrue(NSApplication.shared.sendAction(toggle.action!, to: toggle.target, from: toggle))
        window.layoutIfNeeded()
        XCTAssertFalse(root.splitViewItems[0].isCollapsed)
        XCTAssertFalse(root.splitViewItems[1].isCollapsed)
        XCTAssertEqual(toolbar.items.first?.itemIdentifier, MacAppKitRootController.sidebarToolbarItemIdentifier)
    }

    @MainActor
    func testFullSizeContentKeepsSidebarAndDetailContentBelowTheToolbar() throws {
        let fixture = try makeShippingWindow()
        defer { fixture.cleanup() }
        let (root, window) = fixture.setup
        root.view.layoutSubtreeIfNeeded()
        let layoutTop = window.contentLayoutRect.maxY

        func textFields(in view: NSView) -> [NSTextField] {
            ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(textFields(in:))
        }
        let sidebarView = root.splitViewItems[0].viewController.view
        let sidebarTitle = try XCTUnwrap(textFields(in: sidebarView).first { $0.stringValue == L10n.string("app.name") })
        let sidebarTitleFrame = sidebarTitle.convert(sidebarTitle.bounds, to: nil)
        XCTAssertLessThanOrEqual(sidebarTitleFrame.maxY, layoutTop + 0.5,
                                 "Sidebar content must not slide under the titlebar toggle.")

        let detailContainer = root.splitViewItems[1].viewController.view
        let detailContent = try XCTUnwrap(detailContainer.subviews.first { $0.frame.height > 100 })
        let detailFrame = detailContent.convert(detailContent.bounds, to: nil)
        XCTAssertEqual(detailFrame.maxY, layoutTop, accuracy: 0.5,
                       "Detail content keeps its previous top edge below the toolbar.")
    }

    // MARK: - No tabs, single window

    @MainActor
    func testShippingWindowSetupDisablesNativeWindowTabbing() throws {
        NSWindow.allowsAutomaticWindowTabbing = true
        let fixture = try makeShippingWindow()
        defer { fixture.cleanup() }

        XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing)
        XCTAssertEqual(fixture.setup.window.tabbingMode, .disallowed)
        XCTAssertNil(fixture.setup.window.tabbedWindows)
    }

    @MainActor
    func testProgrammaticWindowDisallowsTabsAndSurvivesClose() {
        let window = EpubToMp3WindowConfiguration.makeMacOSWindow()
        XCTAssertEqual(window.tabbingMode, .disallowed)
        // The delegate keeps one strong reference and re-shows the same window after Cmd+W.
        XCTAssertFalse(window.isReleasedWhenClosed)
    }

    /// Guard for the menu builder. AppKit injects its tab commands at runtime only
    /// while automatic tabbing is allowed; the policy itself is asserted above.
    @MainActor
    func testMainMenuOffersNoTabsOrNewWindowCommands() throws {
        let previousWindowsMenu = NSApp.windowsMenu
        defer { NSApp.windowsMenu = previousWindowsMenu }
        MacApplicationWindowSetup.applyWindowingPolicy()
        XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing)
        let mainMenu = MacApplicationMenu.make()
        func items(in menu: NSMenu) -> [NSMenuItem] {
            menu.items + menu.items.compactMap(\.submenu).flatMap(items(in:))
        }
        let all = items(in: mainMenu)
        let forbidden: Set<String> = [
            "newWindowForTab:", "toggleTabBar:", "toggleTabOverview:", "mergeAllWindows:",
            "moveTabToNewWindow:", "selectNextTab:", "selectPreviousTab:", "newDocument:",
        ]
        XCTAssertTrue(all.compactMap(\.action).map(NSStringFromSelector).allSatisfy { !forbidden.contains($0) })
        XCTAssertFalse(all.contains { $0.keyEquivalent == "t" && $0.keyEquivalentModifierMask == .command })
        XCTAssertFalse(all.contains { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command })

        let commandT = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
            context: nil, characters: "t", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))
        XCTAssertFalse(mainMenu.performKeyEquivalent(with: commandT))
        // Close and Quit remain available.
        XCTAssertTrue(all.contains { $0.action == #selector(NSWindow.performClose(_:)) && $0.keyEquivalent == "w" })
        XCTAssertTrue(all.contains { $0.action == #selector(NSApplication.terminate(_:)) && $0.keyEquivalent == "q" })
    }

    @MainActor
    func testDockReopenReshowsTheSameWindowWithoutCreatingAnother() {
        let window = EpubToMp3WindowConfiguration.makeMacOSWindow()
        defer { window.orderOut(nil); window.close() }
        window.makeKeyAndOrderFront(nil)
        window.orderOut(nil)  // Equivalent visible state after Cmd+W.
        XCTAssertFalse(window.isVisible)
        let windowCount = NSApp.windows.count

        XCTAssertFalse(MacApplicationWindowSetup.handleReopen(window),
                       "The app handled reopen itself; AppKit must not create another window.")
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(NSApp.windows.count, windowCount)

        XCTAssertFalse(MacApplicationWindowSetup.handleReopen(window))
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(NSApp.windows.count, windowCount)
    }

    @MainActor
    func testDelegateReopenNeverAsksAppKitForAnotherWindow() throws {
        let suite = "single-window-delegate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = EpubToMp3App(library: LibraryStore(defaults: defaults, defaultsKey: "library"))
        let windowCount = NSApp.windows.count

        XCTAssertFalse(app.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertFalse(app.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        XCTAssertEqual(NSApp.windows.count, windowCount)
    }
}
#endif
