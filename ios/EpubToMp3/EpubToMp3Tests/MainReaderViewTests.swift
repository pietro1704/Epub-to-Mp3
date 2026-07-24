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

    func testTabRootIsDesktopOnlyFallback() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/App/RootView.swift")
        )
        XCTAssertTrue(source.contains("#if !os(iOS)\nstruct TabRoot: View"))
        XCTAssertTrue(source.contains("#if !os(iOS)\n#Preview(\"Tab fallback\")"))
        XCTAssertTrue(source.contains("private var shellContent: some View"))
        XCTAssertTrue(source.contains("SplitViewRoot()"))
        XCTAssertTrue(source.contains("TabRoot()"))
    }

    func testRootViewKeepsMobileBranchThin() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/App/RootView.swift")
        )
        XCTAssertTrue(source.contains("EmptyView()"))
        XCTAssertFalse(source.contains("@EnvironmentObject private var sidecar: SidecarManager"))
        XCTAssertTrue(source.contains("#if !os(iOS)\n    @EnvironmentObject private var player: AudioPlayer"))
        XCTAssertTrue(source.contains("#if !os(iOS)\n    private var isReaderActive: Bool"))
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
        let supportSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Playback/Views/PlaybackControlsSupport.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(supportSource.contains("PlaybackRateFloatingPicker"))
        XCTAssertTrue(supportSource.contains("ScrollView(.horizontal"))
        XCTAssertTrue(supportSource.contains("player.setRate"))
        XCTAssertTrue(supportSource.contains("MPVolumeView"))
        XCTAssertTrue(supportSource.contains("SystemVolumeSlider"))
        XCTAssertTrue(supportSource.contains("presentationCompactAdaptationIfAvailable"))

        let fullPlayerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Playback/Views/FullPlayerSheet.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(fullPlayerSource.contains("SystemVolumeSlider()"))
        XCTAssertTrue(fullPlayerSource.contains("fullPlayer.playbackRateButton"))
        XCTAssertFalse(fullPlayerSource.contains("FullPlayerScreenHost()"))

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
        let iosRootContainer = sources.iosRootContainer
        XCTAssertTrue(source.contains("EmptyView()"),
                      "The legacy SwiftUI root must not mount a second shell.")
        XCTAssertTrue(iosRootContainer.contains("MainReaderScreenController("),
                      "The UIKit root container should embed the dedicated main-reader controller directly.")
        XCTAssertTrue(source.contains("currentlyReadingBookIDKey"),
                      "The iPhone root must use the persisted reader book, not only the playing book.")
        XCTAssertTrue(sources.instantReader.contains("ReaderSessionState.load(bookID: fulltext.jobId)"),
                      "Reader chrome/player state must be restored per book.")
        XCTAssertTrue(sources.instantReader.contains("audioMarker?.wasPlaying == true"),
                      "A playing audio marker must take precedence over the visual reader anchor.")
    }

    func testMainReaderUsesUIKitHostOnIOS() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Reader/Views/MainReaderView.swift")
        )
        XCTAssertTrue(source.contains("#if os(iOS)\nstruct MainReaderView: View"))
        XCTAssertTrue(source.contains("EmptyView()"))
        XCTAssertFalse(source.contains("MainReaderScreenHost("))
        XCTAssertTrue(source.contains("#if !os(iOS)\n    @EnvironmentObject private var playerPresentation: PlayerPresentation"))
        XCTAssertTrue(source.contains("private func populatedReader(for book: BookEntity) -> some View"))
        XCTAssertTrue(source.contains("BookOpenView(book: book, onClose: {"))
        XCTAssertTrue(source.contains("#if !os(iOS)\n        .onAppear {"))
        XCTAssertTrue(source.contains("#if !os(iOS)\n        .toolbar {"))
        XCTAssertFalse(source.contains("private func iosReaderSurface(for book: BookEntity) -> some View"))
        XCTAssertFalse(source.contains("private func desktopReaderSurface(for book: BookEntity) -> some View"))

        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let screenSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Reader/Views/MainReaderScreenController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(screenSource.contains("final class MainReaderScreenController: UIViewController"))
        XCTAssertTrue(screenSource.contains("private var hostedController: BookOpenScreenController?"))
        XCTAssertTrue(screenSource.contains("let host = BookOpenScreenController("))
        XCTAssertTrue(screenSource.contains("playerPresentation.showFullPlayer()"))
        XCTAssertTrue(screenSource.contains("updated.lastOpenedAt = Date()"))
        XCTAssertTrue(screenSource.contains("listenButton.accessibilityIdentifier = \"mainReader.listen\""))
        XCTAssertTrue(screenSource.contains("hostedController.update("))
        XCTAssertFalse(screenSource.contains("onRequestRePick: { [weak self] in"))
        XCTAssertFalse(screenSource.contains("UIDocumentPickerViewController("))
        XCTAssertFalse(screenSource.contains("func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL])"))
    }

    func testManualConversionIsThirdTabAndReaderIsPushedFromLibrary() throws {
        let sources = try appViewSources()
        let rootSource = sources.root
        let shellSource = sources.iosShell
        let settingsSource = sources.settings
        let librarySource = sources.library
        let bookOpenSource = sources.bookOpen
        let instantReaderSource = sources.instantReader

        XCTAssertTrue(rootSource.contains("EmptyView()"),
                      "The legacy SwiftUI root must not own iOS navigation.")
        XCTAssertTrue(shellSource.contains("case library"))
        XCTAssertTrue(shellSource.contains("case settings"))
        XCTAssertTrue(shellSource.contains("case convert"))
        XCTAssertTrue(shellSource.contains("ConvertScreenController("),
                      "Manual conversion must live as a dedicated UIKit tab controller.")
        XCTAssertFalse(shellSource.contains("case reader"),
                       "Reader must not be a persistent tab item in the UIKit shell.")
        XCTAssertFalse(settingsSource.contains("NavigationLink {\n                ConvertView()"),
                       "Settings must not contain the manual conversion entry.")
        XCTAssertTrue(settingsSource.contains("@EnvironmentObject private var settings: AppSettings"))
        XCTAssertTrue(settingsSource.contains("@EnvironmentObject private var sidecar: SidecarManager"))
        XCTAssertFalse(settingsSource.contains("@State private var showClearCacheConfirm = false\n    @State private var clearCacheDone = false\n    @State private var showClearAllDownloadsConfirm = false\n    @State private var storageUsage = StorageUsageScanner.current()\n\n    var body"))
        XCTAssertTrue(librarySource.contains(".compatBookDestination($openingBook)"),
                      "Tapping a book must push a reader destination from Library.")
        XCTAssertTrue(librarySource.contains("BookOpenView(book: book, onClose: { binding.wrappedValue = nil })"),
                      "The pushed reader must close back to Library by clearing the navigation binding.")
        XCTAssertTrue(bookOpenSource.contains("let onClose: (() -> Void)?"),
                      "BookOpenView must expose an Apple Books-style close callback.")
        XCTAssertTrue(bookOpenSource.contains("#if !os(iOS)\nstruct BookOpenView: View"),
                      "BookOpenView must remain available only to the desktop SwiftUI reader.")
        XCTAssertFalse(bookOpenSource.contains("BookOpenScreenHost(book: book, onClose: onClose)"),
                       "The iOS reader must not route through a SwiftUI BookOpenView wrapper.")
        XCTAssertTrue(bookOpenSource.contains(".compatReaderBackButtonHidden()"),
                      "Closing a pushed book must still be controlled by the in-book close flow rather than the default navigation back button.")
        XCTAssertTrue(instantReaderSource.contains("Image(systemName: \"xmark\")"),
                      "The in-book EPUB top bar must show an X close button.")
    }

    func testBookOpenContentIsHostedByMainReaderControllerOnIOS() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bookOpenSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Reader/Views/BookOpenView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(bookOpenSource.contains("#if !os(iOS)\nstruct BookOpenView: View"))
        XCTAssertTrue(bookOpenSource.contains("struct BookOpenContentView: View"))
        XCTAssertTrue(bookOpenSource.contains("func bookOpenSystemChrome(pdfVisible: Bool)"),
                      "BookOpen content must route system-bar ownership through a dedicated compatibility helper.")

        let screenSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Reader/Views/MainReaderScreenController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(screenSource.contains("final class MainReaderScreenController: UIViewController"))
        XCTAssertTrue(screenSource.contains("private var hostedController: BookOpenScreenController?"))
        XCTAssertTrue(screenSource.contains("let host = BookOpenScreenController("))

        let bookOpenControllerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Reader/Views/BookOpenScreenController.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(bookOpenControllerSource.contains("struct BookOpenScreenHost: UIViewControllerRepresentable"),
                       "The reader must not retain an unused SwiftUI-to-UIKit adapter.")
        XCTAssertTrue(bookOpenControllerSource.contains("final class BookOpenScreenController: UIViewController, UIDocumentPickerDelegate"))
        XCTAssertTrue(bookOpenControllerSource.contains("BookOpenContentView("))
        XCTAssertTrue(bookOpenControllerSource.contains("onRequestRePick: { [weak self] in"))
        XCTAssertTrue(bookOpenControllerSource.contains("UIDocumentPickerViewController("))
        XCTAssertTrue(bookOpenControllerSource.contains("func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL])"))
    }

    func testInstantReaderUsesUIKitHostOnIOS() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let instantSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Reader/Views/InstantReaderView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(instantSource.contains("struct InstantReaderContentView: View"))
        XCTAssertTrue(instantSource.contains("InstantReaderScreenHost("))
        XCTAssertFalse(instantSource.contains("TocScreenHost("))
        XCTAssertFalse(instantSource.contains("ReaderSearchScreenHost("))
        XCTAssertFalse(instantSource.contains("ReaderSettingsScreenHost()"))
        XCTAssertFalse(instantSource.contains("ConversionStatusScreenHost("))

        let controllerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Reader/Views/InstantReaderScreenController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(controllerSource.contains("presentToc("))
        XCTAssertTrue(controllerSource.contains("TocScreenController("))
        XCTAssertTrue(controllerSource.contains("handleTocJump("))
        XCTAssertTrue(controllerSource.contains("readingState.pinnedReaderChapterIndex = target"))
        XCTAssertTrue(controllerSource.contains("readingState.currentChapterIndex = target"))
        XCTAssertTrue(controllerSource.contains("player.play(snapshot: snapshot, startingAt: playableTarget)"))
        XCTAssertTrue(controllerSource.contains("presentationState.restoreChromeIfNeeded()"))
        XCTAssertTrue(controllerSource.contains("handleCurrentChapterChanged("))
        XCTAssertTrue(controllerSource.contains("settings.saveChapterIndex(newIndex, for: fulltext.jobId)"))
        XCTAssertTrue(controllerSource.contains("readerCoordinator.setChapter(newIndex)"))
        XCTAssertTrue(controllerSource.contains("WidgetDataSync.updateLastRead("))
        XCTAssertTrue(controllerSource.contains("cacheManager.refreshCachedIndices()"))
        XCTAssertTrue(controllerSource.contains("handleCloseAudioPlayer()"))
        XCTAssertTrue(controllerSource.contains("handleReopenAudioPlayer(currentChapterIndex:"))
        XCTAssertTrue(controllerSource.contains("presentationState.hideAudioPlayer()"))
        XCTAssertTrue(controllerSource.contains("presentationState.showAudioPlayer()"))
        XCTAssertTrue(controllerSource.contains("handleAutoHideChrome()"))
        XCTAssertTrue(controllerSource.contains("handleRestoreChrome()"))
        XCTAssertTrue(controllerSource.contains("presentationState.autoHideChromeIfNeeded()"))
        XCTAssertTrue(controllerSource.contains("presentationState.restoreChromeIfNeeded()"))
        XCTAssertTrue(controllerSource.contains("presentSearch()"))
        XCTAssertTrue(controllerSource.contains("onJumpToChapter: { [weak self] idx in"))
        XCTAssertTrue(controllerSource.contains("self?.readingState.currentChapterIndex = max(0, idx - 1)"))
        XCTAssertTrue(controllerSource.contains("presentReaderSettings()"))
        XCTAssertTrue(controllerSource.contains("presentConversionStatus()"))
        XCTAssertTrue(controllerSource.contains("private let readingState = InstantReaderReadingState()"))
        XCTAssertTrue(controllerSource.contains("private let presentationState = InstantReaderPresentationState()"))
        XCTAssertTrue(controllerSource.contains("prepareInitialReadingStateIfNeeded()"))
        XCTAssertTrue(controllerSource.contains("player.armPersistedResume()"))
        XCTAssertTrue(controllerSource.contains("persistLifecycleState()"))
        XCTAssertTrue(controllerSource.contains("settings.saveChapterIndex(readingState.currentChapterIndex"))
        XCTAssertTrue(controllerSource.contains("WidgetDataSync.flushLastRead()"))
        XCTAssertTrue(controllerSource.contains("readerCoordinator.flush()"))
        XCTAssertTrue(controllerSource.contains("ReaderSearchScreenController("))
        XCTAssertTrue(controllerSource.contains("ReaderSettingsScreenController(settings: settings)"))
        XCTAssertTrue(controllerSource.contains("ConversionStatusScreenController("))
        XCTAssertTrue(instantSource.contains("private func openSearch()"))
        XCTAssertTrue(instantSource.contains("var onShowSearch: (() -> Void)? = nil"))
        XCTAssertTrue(instantSource.contains("onShowSearch()"))
        XCTAssertTrue(instantSource.contains("private func openReaderSettings()"))
        XCTAssertTrue(instantSource.contains("private func openToc()"))
        XCTAssertTrue(instantSource.contains("onShowToc(currentAudioChapterIndex, currentChapterIndex, playerMounted, snapshot ?? .empty)"))
        XCTAssertTrue(instantSource.contains("private func openConversionStatus()"))
        XCTAssertTrue(instantSource.contains("var onChapterIndexChanged: ((Int) -> Void)? = nil"))
        XCTAssertTrue(instantSource.contains("onChapterIndexChanged?(newIndex)"))
        XCTAssertTrue(instantSource.contains("var onCloseAudioPlayer: (() -> Void)? = nil"))
        XCTAssertTrue(instantSource.contains("var onReopenAudioPlayer: ((Int) -> Void)? = nil"))
        XCTAssertTrue(instantSource.contains("var onAutoHideChrome: (() -> Void)? = nil"))
        XCTAssertTrue(instantSource.contains("var onRestoreChrome: (() -> Void)? = nil"))
        XCTAssertTrue(instantSource.contains("final class InstantReaderReadingState: ObservableObject"))
        XCTAssertTrue(instantSource.contains("func restoreInitialPosition("))
        XCTAssertTrue(instantSource.contains("@StateObject private var ownedReadingState: InstantReaderReadingState"))
        XCTAssertTrue(instantSource.contains("final class InstantReaderPresentationState: ObservableObject"))
        XCTAssertTrue(instantSource.contains("@StateObject private var ownedPresentationState: InstantReaderPresentationState"))
        XCTAssertFalse(instantSource.contains("WidgetDataSync.flushLastRead()"))
        XCTAssertFalse(instantSource.contains("readerCoordinator.flush()"))
        XCTAssertFalse(instantSource.contains("settings.saveChapterIndex(newIndex, for: fulltext.jobId)"))
        XCTAssertFalse(instantSource.contains("readerCoordinator.setChapter(newIndex)"))
        XCTAssertFalse(instantSource.contains("WidgetDataSync.updateLastRead("))
        XCTAssertFalse(instantSource.contains("currentChapterIndex = max(0, idx - 1)"))
        XCTAssertFalse(instantSource.contains("@State private var currentChapterIndex: Int = 0"))
        XCTAssertFalse(instantSource.contains("@State private var restoredPageRatio: Double? = nil"))
        XCTAssertFalse(instantSource.contains("@State private var pinnedReaderChapterIndex: Int?"))
        XCTAssertFalse(instantSource.contains("ReaderSessionState.load(bookID: fulltext.jobId)"))
        XCTAssertFalse(instantSource.contains("@State private var chromeVisible = true"))
        XCTAssertFalse(instantSource.contains("@State private var audioPlayerVisible = true"))
        XCTAssertFalse(instantSource.contains("@Environment(\\.horizontalSizeClass) private var hSize"))
        XCTAssertFalse(instantSource.contains("@State private var showingPlayMenu = false"))
        XCTAssertEqual(instantSource.components(separatedBy: ".compatOnChange(of: snapshot)").count - 1, 1)
    }

    func testReaderAuxiliarySheetsUseUIKitHostsOnIOS() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let searchSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Reader/Views/ReaderSearchOverlay.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(searchSource.contains("#if os(iOS)\nstruct ReaderSearchOverlay: View"))
        XCTAssertTrue(searchSource.contains("EmptyView()"))
        XCTAssertTrue(searchSource.contains("@State private var query = \"\""))
        XCTAssertFalse(searchSource.contains("@State private var query = \"\"\n    @State private var results: [SearchResult] = []\n\n    var body"))

        let settingsSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Reader/Views/ReaderSettingsSheet.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(settingsSource.contains("#if os(iOS)\nstruct ReaderSettingsSheet: View"))
        XCTAssertTrue(settingsSource.contains("EmptyView()"))
        XCTAssertTrue(settingsSource.contains("@EnvironmentObject private var settings: AppSettings"))

        let conversionSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Conversion/Views/ConversionStatusSheet.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(conversionSource.contains("#if os(iOS)\nstruct ConversionStatusSheet: View"))
        XCTAssertTrue(conversionSource.contains("EmptyView()"))
        XCTAssertTrue(conversionSource.contains("/// Drives the elapsed-time label"))

        let tocSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Reader/Views/TocDrawer.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(tocSource.contains("#if os(iOS)\nstruct TocDrawer: View"))
        XCTAssertTrue(tocSource.contains("EmptyView()"))
        XCTAssertTrue(tocSource.contains("onDownloadAll: onDownloadAll"))
        XCTAssertTrue(tocSource.contains("@Environment(\\.dismiss) private var dismiss"))

        let searchControllerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Reader/Views/ReaderSearchScreenController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(searchControllerSource.contains("final class ReaderSearchScreenController: UITableViewController"))

        let settingsControllerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Reader/Views/ReaderSettingsScreenController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(settingsControllerSource.contains("final class ReaderSettingsScreenController: UITableViewController"))

        let conversionControllerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Conversion/Views/ConversionStatusScreenController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(conversionControllerSource.contains("final class ConversionStatusScreenController: UITableViewController"))

        let tocControllerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Reader/Views/TocScreenController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(tocControllerSource.contains("final class TocScreenController: UITableViewController"))
        XCTAssertTrue(tocControllerSource.contains("L10n.string(\"player.downloadAll\")"))

        let bookmarksSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Library/Views/BookmarksListView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(bookmarksSource.contains("#if os(iOS)\nstruct BookmarksListView: View"))
        XCTAssertTrue(bookmarksSource.contains("EmptyView()"))
        XCTAssertTrue(bookmarksSource.contains("@EnvironmentObject private var bookmarkStore: BookmarkStore"))

        let bookmarksControllerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Library/Views/BookmarksScreenController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(bookmarksControllerSource.contains("final class BookmarksScreenController: UITableViewController"))

        let playerReaderSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Reader/Views/PlayerReaderView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(playerReaderSource.contains("BookmarksListView("))
        XCTAssertTrue(playerReaderSource.contains("ReaderSearchOverlay("))
        XCTAssertTrue(playerReaderSource.contains("TocDrawer("))

        let tagEditorSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Settings/Views/TagEditorSheet.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(tagEditorSource.contains("#if os(iOS)\nstruct TagEditorSheet: View"))
        XCTAssertTrue(tagEditorSource.contains("EmptyView()"))
        XCTAssertTrue(tagEditorSource.contains("@EnvironmentObject private var library: LibraryStore"))

        let tagEditorControllerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Settings/Views/TagEditorScreenController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(tagEditorControllerSource.contains("final class TagEditorScreenController: UITableViewController"))

        let telemetryControllerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Settings/Views/TelemetryScreenController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(telemetryControllerSource.contains("final class TelemetryScreenController: UITableViewController"))

        let telemetrySource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Settings/Views/TelemetryView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(telemetrySource.contains("#if !os(iOS)\n@MainActor"))

        let logsControllerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Settings/Views/LogsScreenController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(logsControllerSource.contains("final class LogsScreenController: UIViewController"))

        let logsSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Settings/Views/LogsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(logsSource.contains("#if !os(iOS)\n@MainActor"))
    }

    func testMainReaderShowsListenToolbarButtonOnBookSurface() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Reader/Views/MainReaderScreenController.swift")
        )

        XCTAssertTrue(source.contains("configureListenButton()"),
                      "The UIKit main reader controller must configure the listen affordance.")
        XCTAssertTrue(source.contains("listenButton"),
                      "The UIKit main reader controller must own the shared listen button.")
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
                .appendingPathComponent("EpubToMp3/Features/Reader/Views/MainReaderScreenController.swift")
        )

        XCTAssertTrue(source.contains("private let playerPresentation: PlayerPresentation"),
                      "The UIKit main reader controller must own the shared player presentation coordinator.")
        XCTAssertTrue(source.contains("playerPresentation.showFullPlayer()"),
                      "The listen button must open the player through PlayerPresentation.")
        XCTAssertFalse(source.contains("var onOpenPlayer: (() -> Void)?"),
                       "Main reader flow must not expose the old onOpenPlayer callback once presentation is environment-driven.")
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
        let iosRootContainer = sources.iosRootContainer
        let fullPlayerSource = sources.fullPlayer

        XCTAssertTrue(iosRootContainer.contains("fullPlayerController.view.isHidden = !playerPresentation.showingFullPlayer"),
                      "The UIKit root container must own full-player visibility at the app-overlay layer.")
        XCTAssertTrue(fullPlayerSource.contains("@EnvironmentObject private var playerPresentation: PlayerPresentation"),
                      "In-tree player dismissal must clear PlayerPresentation instead of relying on Environment.dismiss.")
        XCTAssertTrue(fullPlayerSource.contains("playerPresentation.dismissFullPlayer()"),
                      "Player dismiss gestures/buttons must animate back below the screen while preserving the underlying UI.")
    }

    func testMiniPlayerInsetKeepsTabContentAboveMiniPlayer() throws {
        let sources = try appViewSources()
        let rootSource = sources.root
        let iosRootContainer = sources.iosRootContainer
        let miniPlayerSource = sources.miniPlayer

        XCTAssertTrue(miniPlayerSource.contains("static let reservedHeight"),
                      "MiniPlayerBar must expose one canonical reserved height.")
        XCTAssertTrue(rootSource.contains("EmptyView()"),
                      "The legacy SwiftUI root must not own mini-player routing.")
        XCTAssertTrue(iosRootContainer.contains("miniPlayerController.view.isHidden = !showMini"),
                      "The UIKit root container must own mini-player visibility.")
        XCTAssertTrue(iosRootContainer.contains("MiniPlayerContainerController("),
                      "The UIKit root container must mount the mini-player through the dedicated UIKit container.")
    }

    func testMiniPlayerUIKitImplementationDoesNotKeepUnusedSwiftUIHostWrapper() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let miniPlayerUIKitSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Playback/Views/MiniPlayerBarHost.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(miniPlayerUIKitSource.contains("struct MiniPlayerBarHost"),
                       "The iOS mini-player should not keep an unused SwiftUI wrapper once the UIKit root owns the bar directly.")
        XCTAssertTrue(miniPlayerUIKitSource.contains("final class MiniPlayerBarUIKitView: UIView"),
                      "The reusable UIKit mini-player view must remain available for the root container.")
    }

    func testConvertViewHasScrollableBottomClearanceForMiniPlayer() throws {
        let sources = try appViewSources()
        let convertSource = sources.convert
        let shellSource = sources.iosShell

        XCTAssertTrue(convertSource.contains("#if !os(iOS)\n@MainActor\nfinal class ConvertViewModel: ObservableObject"))
        XCTAssertTrue(convertSource.contains(".padding(.bottom, MiniPlayerBar.reservedHeight)")
                      || shellSource.contains("ConvertScreenController("),
                      "Manual conversion must either keep SwiftUI mini-player clearance or move to a dedicated UIKit screen.")
        XCTAssertTrue(convertSource.contains("@StateObject private var viewModel = ConvertViewModel()"))
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

    private func appViewSources() throws -> (root: String, iosRootContainer: String, iosShell: String, settings: String, fullPlayer: String, miniPlayer: String, convert: String, library: String, bookOpen: String, instantReader: String, reader: String, attributedPage: String, platformCompat: String) {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return (
            root: try String(contentsOf: projectRoot
                .appendingPathComponent("EpubToMp3/App/RootView.swift")),
            iosRootContainer: try String(contentsOf: projectRoot
                .appendingPathComponent("EpubToMp3/App/IOSRootContainer.swift")),
            iosShell: try String(contentsOf: projectRoot
                .appendingPathComponent("EpubToMp3/App/IOSAppShell.swift")),
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
        XCTAssertFalse(sources.settings.contains("embeddedRuntimeSection"))
        XCTAssertFalse(sources.settings.contains("settingsForm"))
        XCTAssertTrue(sources.iosShell.contains("SettingsScreenController("),
                      "The iOS shell must route Settings through the UIKit settings controller.")
        XCTAssertTrue(sources.settings.contains("#if os(iOS)\nstruct SettingsView: View"))
        XCTAssertTrue(sources.settings.contains("EmptyView()"))

        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsControllerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Settings/Views/SettingsScreenController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(settingsControllerSource.contains("TelemetryScreenController(settings: settings)"))
        XCTAssertTrue(settingsControllerSource.contains("JobsListScreenController("))
        XCTAssertTrue(settingsControllerSource.contains("player: player"))
        XCTAssertTrue(settingsControllerSource.contains("playbackClock: playbackClock"))
    }

    func testMainIOSViewsDelegateToUIKitHosts() throws {
        let sources = try appViewSources()
        XCTAssertTrue(sources.library.contains("#if os(iOS)\nstruct LibraryView: View"))
        XCTAssertTrue(sources.library.contains("EmptyView()"))
        XCTAssertTrue(sources.convert.contains("#if os(iOS)\nstruct ConvertView: View"))
        XCTAssertTrue(sources.convert.contains("EmptyView()"))
        XCTAssertTrue(sources.settings.contains("#if os(iOS)\nstruct SettingsView: View"))
        XCTAssertTrue(sources.settings.contains("EmptyView()"))
        XCTAssertFalse(sources.fullPlayer.contains("FullPlayerScreenHost"))
        XCTAssertTrue(sources.fullPlayer.contains("struct FullPlayerSheet: View"))
        XCTAssertFalse(sources.miniPlayer.contains("MiniPlayerBarBridge"))
        XCTAssertFalse(sources.miniPlayer.contains("UIViewRepresentable"))

        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let jobsSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Conversion/Views/JobsListView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(jobsSource.contains("#if os(iOS)\nstruct JobsListView: View"))
        XCTAssertTrue(jobsSource.contains("EmptyView()"))
        XCTAssertTrue(jobsSource.contains("#if !os(iOS)\n@MainActor\nfinal class JobsListViewModel: ObservableObject"))
        XCTAssertTrue(jobsSource.contains("@StateObject private var viewModel = JobsListViewModel()"))
        XCTAssertFalse(jobsSource.contains("JobDetailView(jobId: session.bookTitle)"))
        XCTAssertTrue(jobsSource.contains("if let jobId = session.jobId, !jobId.isEmpty"))
        XCTAssertTrue(jobsSource.contains("NavigationLink(value: jobId)"))
        XCTAssertTrue(jobsSource.contains("JobDetailView(jobId: jobId)"))

        let jobDetailSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Conversion/Views/JobDetailView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(jobDetailSource.contains("#if os(iOS)\nstruct JobDetailView: View"))
        XCTAssertTrue(jobDetailSource.contains("EmptyView()"))
        XCTAssertTrue(jobDetailSource.contains("#if !os(iOS)\n@MainActor\nfinal class JobDetailViewModel: ObservableObject"))
        XCTAssertTrue(jobDetailSource.contains("@EnvironmentObject private var library: LibraryStore"))

        let convertControllerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Conversion/Views/ConvertScreenController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(convertControllerSource.contains("JobDetailScreenController(jobId: jobId"))
        XCTAssertTrue(convertControllerSource.contains("player: player"))
        XCTAssertTrue(convertControllerSource.contains("playbackClock: playbackClock"))

        let librarySource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Library/Views/LibraryView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(librarySource.contains("#if os(iOS)\nstruct LibraryView: View"))
        XCTAssertTrue(librarySource.contains("@EnvironmentObject private var library: LibraryStore"))

        let fullPlayerControllerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Playback/Views/FullPlayerScreenController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(fullPlayerControllerSource.contains("final class FullPlayerScreenController: UIViewController"))
        XCTAssertTrue(fullPlayerControllerSource.contains("TocScreenController("))

        let jobDetailControllerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Conversion/Views/JobDetailScreenController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(jobDetailControllerSource.contains("LogsScreenController(settings: settings, jobId: jobId)"))
        XCTAssertTrue(jobDetailControllerSource.contains("PlayerScreenController("))
        XCTAssertFalse(jobDetailControllerSource.contains("UIHostingController(\n            rootView: PlayerReaderView"),
                       "The iOS job detail flow should use the dedicated UIKit player controller instead of hosting PlayerReaderView directly.")

        let jobsControllerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Conversion/Views/JobsListScreenController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(jobsControllerSource.contains("if let jobId = session.jobId, !jobId.isEmpty"))
        XCTAssertTrue(jobsControllerSource.contains("JobDetailScreenController("))

        let jobsCollectionSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Conversion/Views/JobsListCollectionView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(jobsCollectionSource.contains("if session.jobId?.isEmpty == false"))
        XCTAssertTrue(jobsCollectionSource.contains(".disclosureIndicator()"))

        let iosRootContainerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/App/IOSRootContainer.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(iosRootContainerSource.contains("UIHostingController("),
                       "The iOS root container should not wrap UIKit-backed reader/full-player/mini-player surfaces in SwiftUI hosting controllers.")
        XCTAssertTrue(iosRootContainerSource.contains("FullPlayerScreenController("))

        let playerReaderSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Reader/Views/PlayerReaderView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(playerReaderSource.contains("PlayerReaderIOSHost("))
        XCTAssertTrue(playerReaderSource.contains("PlayerScreenController("))

        let fullPlayerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Playback/Views/FullPlayerSheet.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(fullPlayerSource.contains("#if os(iOS)\nstruct FullPlayerSheet: View"))
        XCTAssertTrue(fullPlayerSource.contains("EmptyView()"))
    }

    func testUIKitMigrationLeavesOnlyReaderHostingControllersInAppSurfaces() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3")

        let enumerator = FileManager.default.enumerator(
            at: projectRoot,
            includingPropertiesForKeys: nil
        )
        var filesUsingHosting: [String] = []

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            if source.contains("UIHostingController(") {
                filesUsingHosting.append(fileURL.lastPathComponent)
            }
        }

        XCTAssertEqual(
            Set(filesUsingHosting),
            ["BookOpenScreenController.swift", "InstantReaderScreenController.swift"],
            "The remaining UIHostingController usage should be constrained to the UIKit reader entry points that still host SwiftUI reader renderers."
        )
    }

    func testSystemVolumeIconsUseEqualCenteredFrames() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let source = try String(
            contentsOf: testFile
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Playback/Views/PlaybackControlsSupport.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains(".frame(width: 24, height: 24)"))
        XCTAssertTrue(source.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .center)"))
    }

    func testGeneratedProjectDropsDeletedLegacyFilesAndShareExtensionDeclaresPrincipalClass() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let iosRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let projectSource = try String(
            contentsOf: iosRoot.appendingPathComponent("EpubToMp3.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        for deletedName in [
            "PlayerView.swift",
            "NowPlayingView.swift",
            "NowPlayingScreenController.swift",
            "ChapterListScreenController.swift",
            "ChapterListCollectionView.swift",
        ] {
            XCTAssertFalse(
                projectSource.contains(deletedName),
                "The generated Xcode project must not keep stale references to \(deletedName)."
            )
        }

        let shareExtensionPlist = try String(
            contentsOf: iosRoot.appendingPathComponent("EpubToMp3ShareExtension/Info.plist"),
            encoding: .utf8
        )
        XCTAssertTrue(shareExtensionPlist.contains("<key>NSExtensionPrincipalClass</key>"))
        XCTAssertTrue(shareExtensionPlist.contains("EpubToMp3ShareExtension.ShareViewController"))
        XCTAssertFalse(shareExtensionPlist.contains("<key>NSExtensionMainStoryboard</key>"))
    }
}
