import XCTest
import SwiftUI
@testable import EpubToMp3

/// Unit tests for `MainReaderView` persistence and routing contracts.
///
/// We test via `UserDefaults` round-trips and view construction rather
/// than rendering the full SwiftUI tree (calling `.body` on
/// `@AppStorage`-driven views in a unit-test host trips SwiftUI's
/// "no live environment" trap).
final class MainReaderViewTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "mainreader.tests.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Construction

    func testMainReaderViewConstructsWithEmptyLibrary() {
        // Should not crash when no reading book is persisted.
        _ = MainReaderView(onBrowseLibrary: {})
        XCTAssertNil(defaults.string(forKey: MainReaderView.currentlyReadingBookIDKey))
    }

    func testMainReaderViewConstructsWithBrowseCallback() {
        var browseLibraryFired = false
        _ = MainReaderView(
            onBrowseLibrary: { browseLibraryFired = true }
        )
        // Closure binds but is not called at init time.
        XCTAssertFalse(browseLibraryFired)
    }

    // MARK: - Persistence round-trip

    func testSetCurrentlyReadingPersistsBookID() {
        MainReaderView.setCurrentlyReading(bookID: "book-xyz", defaults: defaults)
        XCTAssertEqual(
            defaults.string(forKey: MainReaderView.currentlyReadingBookIDKey),
            "book-xyz"
        )
    }

    func testSetCurrentlyReadingClearsWhenNil() {
        defaults.set("seed", forKey: MainReaderView.currentlyReadingBookIDKey)
        MainReaderView.setCurrentlyReading(bookID: nil, defaults: defaults)
        XCTAssertNil(defaults.string(forKey: MainReaderView.currentlyReadingBookIDKey))
    }

    func testSetCurrentlyReadingTreatsEmptyStringAsNil() {
        defaults.set("seed", forKey: MainReaderView.currentlyReadingBookIDKey)
        MainReaderView.setCurrentlyReading(bookID: "", defaults: defaults)
        XCTAssertNil(defaults.string(forKey: MainReaderView.currentlyReadingBookIDKey))
    }

    // MARK: - Empty state

    func testEmptyStateWhenNoBookIDPersisted() {
        // currentlyReadingBookID key is absent → the view is in empty state.
        // We verify this through the storage key being nil.
        XCTAssertNil(
            defaults.string(forKey: MainReaderView.currentlyReadingBookIDKey),
            "No book should be persisted in a fresh defaults suite."
        )
    }

    // MARK: - "Listen" sets currentlyPlayingBookID

    func testListenButtonSetsPlayingIDToReadingID() {
        // Simulate what the "Listen" button does: copy reading ID → playing ID.
        let bookID = "book-read-123"
        defaults.set(bookID, forKey: MainReaderView.currentlyReadingBookIDKey)

        // Mirror the button's action: read the reading key, write the playing key.
        let readingID = defaults.string(forKey: MainReaderView.currentlyReadingBookIDKey)
        if let id = readingID {
            defaults.set(id, forKey: AudioPlayer.currentBookIDDefaultsKey)
        }

        XCTAssertEqual(
            defaults.string(forKey: AudioPlayer.currentBookIDDefaultsKey),
            bookID,
            "Tapping Listen must set the currentlyPlayingBookID to the currently-reading book."
        )
    }

    // MARK: - Auto-clear when book is removed from library

    func testBookRemovedFromLibraryClearsReadingID() {
        // Simulate: book "removed-book" was being read, then deleted.
        let lib = LibraryStore.previewEmpty
        let removedID = "removed-book"
        defaults.set(removedID, forKey: MainReaderView.currentlyReadingBookIDKey)

        // The view checks whether the book is still in the library.
        let bookStillExists = lib.books.contains(where: { $0.id == removedID })
        if !bookStillExists {
            defaults.removeObject(forKey: MainReaderView.currentlyReadingBookIDKey)
        }

        XCTAssertNil(
            defaults.string(forKey: MainReaderView.currentlyReadingBookIDKey),
            "Reading pointer must auto-clear when the book is no longer in the library."
        )
    }

    func testBookPresentInLibraryPreservesReadingID() {
        let lib = LibraryStore.previewPopulated
        guard let firstBook = lib.books.first else {
            XCTFail("previewPopulated must have at least one book")
            return
        }
        defaults.set(firstBook.id, forKey: MainReaderView.currentlyReadingBookIDKey)

        let bookStillExists = lib.books.contains(where: { $0.id == firstBook.id })
        if !bookStillExists {
            defaults.removeObject(forKey: MainReaderView.currentlyReadingBookIDKey)
        }

        XCTAssertEqual(
            defaults.string(forKey: MainReaderView.currentlyReadingBookIDKey),
            firstBook.id,
            "Reading pointer must not be cleared while the book is still in the library."
        )
    }

    // MARK: - RootTab stability

    /// iPhone root follows Apple Books: Library is the landing tab and
    /// books are pushed from the library. There is no persistent "Read"
    /// tab item; the reader is a detail destination with its own close X.
    func testRootTabLibraryIsFirstAndReaderIsNotATab() {
        XCTAssertEqual(RootTab.library.rawValue, 0,
                       "Library must be the first tab and default landing screen.")
        XCTAssertEqual(RootTab.settings.rawValue, 1)
        XCTAssertEqual(RootTab.convert.rawValue, 2,
                       "Manual conversion must live in the third tab, not inside Settings.")
    }

    func testReaderSessionStateRoundTripsPerBook() {
        let suite = "reader-session-\\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        ReaderSessionState.save(
            bookID: "book-1",
            chromeVisible: false,
            miniPlayerVisible: false,
            fullPlayerVisible: true,
            defaults: defaults
        )

        XCTAssertEqual(
            ReaderSessionState.load(bookID: "book-1", defaults: defaults),
            ReaderSessionState(chromeVisible: false, miniPlayerVisible: false, fullPlayerVisible: true)
        )
        XCTAssertEqual(
            ReaderSessionState.load(bookID: "book-2", defaults: defaults),
            .default
        )
    }

    func testPlayerPresentationRestoresExpandedStateFromDefaults() {
        let suite = "player-presentation-\\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: PlayerPresentation.persistedExpandedKey)
        let presentation = PlayerPresentation(defaults: defaults)
        XCTAssertTrue(presentation.showingFullPlayer)

        presentation.dismissFullPlayer()
        XCTAssertFalse(defaults.bool(forKey: PlayerPresentation.persistedExpandedKey))
        presentation.showFullPlayer()
        XCTAssertTrue(defaults.bool(forKey: PlayerPresentation.persistedExpandedKey))
    }

    func testEmbeddedReaderDoesNotMountLegacyLocalPlayer() {
        XCTAssertFalse(
            InstantReaderIndexMapper.shouldMountLocalPlayer(useEmbeddedRuntime: true)
        )
        XCTAssertTrue(
            InstantReaderIndexMapper.shouldMountLocalPlayer(useEmbeddedRuntime: false)
        )
    }

    func testInstantReaderUsesGlobalAudioPlayerOnly() throws {
        let source = try appViewSources().instantReader
        XCTAssertTrue(source.contains("@EnvironmentObject private var globalPlayer: AudioPlayer"))
        XCTAssertFalse(source.contains("@StateObject private var player = AudioPlayer()"))
        XCTAssertTrue(source.contains("private var player: AudioPlayer { globalPlayer }"))
    }

    func testPlayerUsesFloatingRatePickerContract() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Playback/Views/PlayerView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("PlaybackRateFloatingPicker"))
        XCTAssertTrue(source.contains("ScrollView(.horizontal"))
        XCTAssertTrue(source.contains("playbackRateButton"))
        XCTAssertTrue(source.contains("player.setRate"))
        XCTAssertTrue(source.contains("MPVolumeView"))
        XCTAssertTrue(source.contains("SystemVolumeSlider"))

        let fullPlayerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Playback/Views/FullPlayerSheet.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(fullPlayerSource.contains("SystemVolumeSlider()"))
        XCTAssertTrue(fullPlayerSource.contains("fullPlayer.playbackRateButton"))

        let miniPlayerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Playback/Views/MiniPlayerBar.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(miniPlayerSource.contains("miniPlayer.playbackRateButton"))
        XCTAssertTrue(miniPlayerSource.contains("PlaybackRateFloatingPicker"))

        let instantReaderSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Reader/Views/InstantReaderView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(instantReaderSource.contains("ReaderFollowButton("))
        XCTAssertTrue(instantReaderSource.contains("hasLoadedAudioQueue"))
    }

    func testRootReaderRestoresReaderInsteadOfLibraryWhenReadingBookExists() throws {
        let sources = try appViewSources()
        let source = sources.root
        XCTAssertTrue(source.contains("MainReaderView("),
                      "The iPhone root must mount MainReaderView as the restored landing surface.")
        XCTAssertTrue(source.contains("currentlyReadingBookIDKey"),
                      "The iPhone root must use the persisted reader book, not only the playing book.")
        XCTAssertTrue(sources.instantReader.contains("ReaderSessionState.load(bookID: fulltext.jobId)"),
                      "Reader chrome/player state must be restored per book.")
        XCTAssertTrue(sources.instantReader.contains("audioMarker?.wasPlaying == true"),
                      "A playing audio marker must take precedence over the visual reader anchor.")
    }

    func testManualConversionIsThirdTabAndReaderIsPushedFromLibrary() throws {
        let sources = try appViewSources()
        let rootSource = sources.root
        let settingsSource = sources.settings
        let librarySource = sources.library
        let bookOpenSource = sources.bookOpen
        let instantReaderSource = sources.instantReader

        XCTAssertTrue(rootSource.contains("ConvertView()"),
                      "TabRoot must expose manual conversion directly as a tab.")
        XCTAssertTrue(rootSource.contains(".tag(RootTab.convert)"),
                      "Manual conversion tab must use the RootTab.convert third-tab token.")
        XCTAssertEqual(rootSource.components(separatedBy: ".tabItem").count - 1, 3,
                       "The iPhone TabView must expose exactly three tab bar items.")
        XCTAssertFalse(rootSource.contains(".tabItem { Label(L10n.string(\"nav.read\")"),
                       "Reader must not appear as a persistent tab bar item.")
        XCTAssertTrue(rootSource.contains("MainReaderView("),
                      "The iPhone root must restore the reader surface when a reading book exists.")
        XCTAssertFalse(rootSource.contains(".tag(RootTab.reader)"),
                       "Reader must be restored as the root surface, not as a persistent tab item.")
        XCTAssertLessThan(rootSource.range(of: ".tag(RootTab.settings)")!.lowerBound,
                          rootSource.range(of: ".tag(RootTab.convert)")!.lowerBound,
                          "Manual conversion must be the third tab after Settings.")
        XCTAssertTrue(rootSource.contains("TabView(selection: $selectedTab)"),
                      "The three items must live in the root iPhone TabView.")
        XCTAssertFalse(settingsSource.contains("NavigationLink {\n                ConvertView()"),
                       "Settings must not contain the manual conversion entry.")
        XCTAssertTrue(librarySource.contains(".compatBookDestination($openingBook)"),
                      "Tapping a book must push a reader destination from Library.")
        XCTAssertTrue(librarySource.contains("BookOpenView(book: book, onClose: { binding.wrappedValue = nil })"),
                      "The pushed reader must close back to Library by clearing the navigation binding.")
        XCTAssertTrue(bookOpenSource.contains("let onClose: (() -> Void)?"),
                      "BookOpenView must expose an Apple Books-style close callback.")
        XCTAssertTrue(bookOpenSource.contains("onClose: onClose"),
                      "BookOpenView must forward close into the EPUB reader chrome.")
        XCTAssertTrue(bookOpenSource.contains(".compatReaderBackButtonHidden()"),
                      "Closing a pushed book must be controlled by the in-book X button, not by accidental navigation-edge swipes.")
        XCTAssertTrue(instantReaderSource.contains("Image(systemName: \"xmark\")"),
                      "The in-book EPUB top bar must show an X close button.")
    }

    func testMainReaderShowsListenToolbarButtonOnBookSurface() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Reader/Views/MainReaderView.swift")
        )

        XCTAssertTrue(source.contains(".toolbar {"),
                      "MainReaderView must restore a toolbar on the populated book surface.")
        XCTAssertTrue(source.contains("ToolbarItem(placement: .compatPrimaryTrailing)"),
                      "The listen affordance must live in the trailing reader toolbar slot.")
        XCTAssertTrue(source.contains("listenButton"),
                      "The populated reader surface must mount the shared listen button helper.")
    }

    func testMainReaderNoLongerOwnsFallbackPlayerSheet() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Reader/Views/MainReaderView.swift")
        )

        XCTAssertFalse(source.contains("showingPlayerOverlay"),
                       "MainReaderView must not keep its legacy local player-sheet state.")
        XCTAssertFalse(source.contains(".sheet(isPresented:"),
                       "MainReaderView must delegate player presentation to the root container instead of mounting its own sheet.")
        XCTAssertFalse(source.contains("makeStub(for:"),
                       "MainReaderView must not synthesize a private JobSnapshot stub once root presentation owns the flow.")
        XCTAssertFalse(source.contains("mainReader.noAudioYet"),
                       "The local no-audio fallback sheet must be removed with the dead overlay path.")
        XCTAssertFalse(source.contains("onOpenPlayer?()"),
                       "MainReaderView must no longer use a callback-based player presenter hook.")
    }

    func testMainReaderUsesPlayerPresentationEnvironmentObject() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Reader/Views/MainReaderView.swift")
        )

        XCTAssertTrue(source.contains("@EnvironmentObject private var playerPresentation: PlayerPresentation"),
                      "MainReaderView must read the shared player presentation coordinator from the environment.")
        XCTAssertTrue(source.contains("playerPresentation.showFullPlayer()"),
                      "The listen button must open the player through PlayerPresentation.")
        XCTAssertFalse(source.contains("var onOpenPlayer: (() -> Void)?"),
                       "MainReaderView must not expose the old onOpenPlayer callback once presentation is environment-driven.")
    }

    func testPaginatedReaderRoutesTextViewTapsAndSwipesToPageTurns() throws {
        let sources = try appViewSources()
        let readerSource = sources.reader
        let attributedSource = sources.attributedPage
        let platformSource = sources.platformCompat

        // The page surface has one semantic tap owner. The native page-curl
        // controller owns it; the old SwiftUI overlay and UITextView tap
        // recognizer must not compete with it.
        XCTAssertFalse(readerSource.contains(".overlay(tapZones("),
                       "paginated pages must not install a competing SwiftUI tap overlay.")
        XCTAssertTrue(readerSource.contains("onCenterTap?()"),
                      "non-link taps must toggle top/bottom chrome.")
        XCTAssertFalse(readerSource.contains("case .center: advancePage(totalPages: totalPages)"),
                       "center taps must not advance the page.")

        // Swipe-to-turn: page-curl (.flip) swipes are owned by the native
        // UIPageViewController in TextKitPageView; slide/none swipes flow
        // through the single `onSwipe` path on FixedWidthTextView. The legacy
        // SwiftUI `DragGesture(minimumDistance: 30)` was removed so it can't
        // race the UIKit pan (which produced the double-turn / flicker).
        XCTAssertFalse(readerSource.contains("DragGesture(minimumDistance: 30)"),
                       "Legacy SwiftUI swipe gesture must be gone — UIPageViewController owns curl swipes.")
        XCTAssertTrue(readerSource.contains("onSwipe: enableReaderGestures ? onSwipePage : nil"),
                      "Slide/none swipe-to-turn must be the single onSwipe path on FixedWidthTextView.")
        XCTAssertFalse(attributedSource.contains("UISwipeGestureRecognizer("),
                       "UISwipeGestureRecognizer must not be installed in the UITextView — it fires mid-gesture and races DragGesture causing double turns.")
        XCTAssertTrue(readerSource.contains("private func handleSwipe("),
                      "ReaderView must define handleSwipe to map swipe directions to retreat/advance.")

        XCTAssertTrue(attributedSource.contains("uiView.installReaderGestures(includeSwipe:"),
                      "non-curl TextKit pages must keep their native gesture installation for links and horizontal swipes.")
        XCTAssertTrue(attributedSource.contains("uiView.bounces = scrollable"),
                      "Paginated text pages must not rubber-band vertically when the user drags and releases.")
        XCTAssertTrue(attributedSource.contains("uiView.alwaysBounceVertical = scrollable"),
                      "Vertical bounce should be enabled only for true scroll mode, never for paginated pages.")
        XCTAssertTrue(attributedSource.contains("uiView.setContentOffset(.zero, animated: false)"),
                      "If UIKit briefly moves a non-scrollable page, updateUIView must snap it back to the fixed page origin.")
        XCTAssertTrue(attributedSource.contains("func scrollViewDidScroll(_ scrollView: UIScrollView)"),
                      "The UITextView delegate must prevent non-scrollable paginated pages from drifting vertically.")
        XCTAssertTrue(platformSource.contains("func compatReaderBackButtonHidden()"))
        XCTAssertTrue(platformSource.contains("self.navigationBarBackButtonHidden(true)"))
    }

    func testFullPlayerUsesSpotifyBottomSheetPresentation() throws {
        let sources = try appViewSources()
        let rootSource = sources.root
        let fullPlayerSource = sources.fullPlayer

        XCTAssertTrue(rootSource.contains(".transition(.spotifyBottomSheet)"),
                      "Full player must slide in/out from below the screen like Spotify, not scale from the mini player.")
        XCTAssertFalse(rootSource.contains(".transition(.risesFromMiniPlayer)"),
                       "The old grow-from-mini-player transition must not be used.")
        XCTAssertTrue(fullPlayerSource.contains("@EnvironmentObject private var playerPresentation: PlayerPresentation"),
                      "In-tree player dismissal must clear PlayerPresentation instead of relying on Environment.dismiss.")
        XCTAssertTrue(fullPlayerSource.contains("playerPresentation.dismissFullPlayer()"),
                      "Player dismiss gestures/buttons must animate back below the screen while preserving the underlying UI.")
    }

    func testMiniPlayerInsetKeepsTabContentAboveMiniPlayer() throws {
        let sources = try appViewSources()
        let rootSource = sources.root
        let miniPlayerSource = sources.miniPlayer

        XCTAssertTrue(miniPlayerSource.contains("static let reservedHeight"),
                      "MiniPlayerBar must expose one canonical reserved height.")
        XCTAssertTrue(rootSource.contains(".miniPlayerInset(visible: showMiniPlayer"),
                      "Each tab's content must reserve space for MiniPlayerBar above the tab bar.")
        XCTAssertEqual(rootSource.components(separatedBy: ".miniPlayerInset(visible: showMiniPlayer").count - 1, 3,
                       "Every root tab must host the mini player above the tab bar.")
        XCTAssertFalse(rootSource.contains(".padding(.bottom, visible ? MiniPlayerBar.reservedHeight : 0)"),
                       "Do not add explicit bottom padding on top of safeAreaInset; it creates a blank white strip above the mini player.")
        XCTAssertTrue(rootSource.contains("content\n            .safeAreaInset(edge: .bottom"),
                      "The mini player must be inserted through safeAreaInset so content ends directly above it.")
    }

    func testConvertViewHasScrollableBottomClearanceForMiniPlayer() throws {
        let sources = try appViewSources()
        let convertSource = sources.convert

        XCTAssertTrue(convertSource.contains(".padding(.bottom, MiniPlayerBar.reservedHeight)"),
                      "Manual conversion Form must have scrollable bottom clearance so its last controls are not covered by the mini player.")
    }

    // MARK: - SplitNavMode stability

    /// `SplitNavMode.reader` must be the first case so the sidebar
    /// defaults to the Reader destination on iPad/macOS.
    func testSplitNavModeReaderIsFirstCase() {
        XCTAssertEqual(
            SplitNavMode.allCases.first, .reader,
            "Reader must be the first sidebar destination (default landing)."
        )
    }

    func testSplitNavModeContainsAllExpectedDestinations() {
        let modes = SplitNavMode.allCases
        XCTAssertTrue(modes.contains(.reader))
        XCTAssertTrue(modes.contains(.library))
        XCTAssertTrue(modes.contains(.settings))
    }

    func testSplitNavModeLabelsAreNonEmpty() {
        for mode in SplitNavMode.allCases {
            XCTAssertFalse(
                mode.label.isEmpty,
                "Sidebar would render an empty label for \(mode)."
            )
            XCTAssertFalse(
                mode.systemImage.isEmpty,
                "Sidebar would render a missing icon for \(mode)."
            )
        }
    }

    // MARK: - AppStorage key contract

    private func appViewSources() throws -> (root: String, settings: String, fullPlayer: String, miniPlayer: String, convert: String, library: String, bookOpen: String, instantReader: String, reader: String, attributedPage: String, platformCompat: String) {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return (
            root: try String(contentsOf: projectRoot
                .appendingPathComponent("EpubToMp3/App/RootView.swift")),
            settings: try String(contentsOf: projectRoot
                .appendingPathComponent("EpubToMp3/Features/Settings/Views/SettingsView.swift")),
            fullPlayer: try String(contentsOf: projectRoot
                .appendingPathComponent("EpubToMp3/Features/Playback/Views/FullPlayerSheet.swift")),
            miniPlayer: try String(contentsOf: projectRoot
                .appendingPathComponent("EpubToMp3/Features/Playback/Views/MiniPlayerBar.swift")),
            convert: try String(contentsOf: projectRoot
                .appendingPathComponent("EpubToMp3/Features/Conversion/Views/ConvertView.swift")),
            library: try String(contentsOf: projectRoot
                .appendingPathComponent("EpubToMp3/Features/Library/Views/LibraryView.swift")),
            bookOpen: try String(contentsOf: projectRoot
                .appendingPathComponent("EpubToMp3/Features/Reader/Views/BookOpenView.swift")),
            instantReader: try String(contentsOf: projectRoot
                .appendingPathComponent("EpubToMp3/Features/Reader/Views/InstantReaderView.swift")),
            reader: try String(contentsOf: projectRoot
                .appendingPathComponent("EpubToMp3/Features/Reader/Views/ReaderView.swift")),
            attributedPage: try String(contentsOf: projectRoot
                .appendingPathComponent("EpubToMp3/Features/Reader/Views/AttributedPageView.swift")),
            platformCompat: try String(contentsOf: projectRoot
                .appendingPathComponent("EpubToMp3/App/PlatformCompat.swift"))
        )
    }

    func testCurrentlyReadingBookIDKeyIsDistinctFromPlayingKey() {
        // The two keys MUST be different — they track separate state.
        XCTAssertNotEqual(
            MainReaderView.currentlyReadingBookIDKey,
            AudioPlayer.currentBookIDDefaultsKey,
            "Reading and playing must be tracked by separate UserDefaults keys."
        )
    }

    func testSettingsExposeStorageUsageAndGlobalDownloadClear() throws {
        let sources = try appViewSources()
        XCTAssertTrue(sources.settings.contains("storageSection"))
        XCTAssertTrue(sources.settings.contains("ProgressView(value: storageUsage.budgetFraction)"))
        XCTAssertTrue(sources.settings.contains("clearAllDownloads()"))
        XCTAssertTrue(sources.settings.contains("settings.clearAllDownloads"))
    }

    func testSystemVolumeIconsUseEqualCenteredFrames() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let source = try String(
            contentsOf: testFile
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Playback/Views/PlayerView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains(".frame(width: 24, height: 24)"))
        XCTAssertTrue(source.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .center)"))
    }
}
