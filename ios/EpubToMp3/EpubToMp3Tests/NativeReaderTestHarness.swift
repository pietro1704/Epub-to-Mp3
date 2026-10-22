import XCTest
@testable import EpubToMp3
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Exercises the installed native views and presentation seams with isolated
/// preferences and renderer archives, without opening files or starting audio.
@MainActor
final class NativeReaderTestHarness {
    let id = "native-reader-seam-\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: AppSettings
    let bookmarks: BookmarkStore
    let renderer: PreparedChapterRenderer
    let archiveDirectory: URL
    let book: BookEntity
    let player: AudioPlayer
    private let anchorKeys = [AudioPlayer.readerCurrentChapterIndexDefaultsKey,
        AudioPlayer.readerCurrentPageRatioDefaultsKey, AudioPlayer.readerCurrentSentenceIdDefaultsKey,
        AudioPlayer.currentBookIDDefaultsKey, ReaderSessionState.currentlyReadingBookIDKey]
    private var savedAnchors: [Any?] = []
    var persisted = 0
    var renderedIndices: [Int] = []
#if os(macOS)
    let controller = NSViewController()
    let document = MacReaderDocument()
    lazy var composition: MacReaderViewComposition = MacReaderViewComposition(
        view: controller.view, target: controller, settings: settings,
        actions: .init(close: #selector(NSViewController.loadView), contents: #selector(NSViewController.loadView),
            search: #selector(NSViewController.loadView), settings: #selector(NSViewController.loadView),
            retryLoading: #selector(NSViewController.loadView)), cancelJourney: {},
        onLink: { [weak self] in self?.annotations.handleReaderLink($0, linkText: $1) ?? true },
        onKeyDown: { _ in false }, onPageTap: { _ in },
        onBuildSelectionMenu: { [weak self] in self?.annotations.buildSelectionMenuItems(range: $0) ?? [] }
    )
    lazy var annotations: MacReaderAnnotationsPresentation = MacReaderAnnotationsPresentation(
        document: document, composition: composition, bookmarkStore: bookmarks,
        persistProgress: { [weak self] in self?.persisted += 1 },
        showChapter: { [weak self] in self?.showChapter($0) }
    )
    lazy var text: MacReaderTextPresentation = MacReaderTextPresentation(
        document: document, composition: composition, settings: settings, renderer: renderer,
        initialPositionScheduler: { $0() }, stageObserver: nil,
        repaintSavedHighlights: { [weak self] in self?.annotations.repaintSavedHighlights(chapterIndex: $0) },
        prepareChapterProjection: { _, _ in }, selectCurrentTOCRow: {}, closeReader: {}
    )
    var displayed: NSAttributedString { composition.textView.attributedString() }
#else
    let controller = UIViewController()
    let document: ReaderBookDocument
    private let delegates = NativeReaderNoopDelegates()
    lazy var composition: ReaderViewComposition = ReaderViewComposition(
        view: controller.view, target: controller,
        actions: .init(readerTap: #selector(UIViewController.viewDidLoad), chapterForward: #selector(UIViewController.viewDidLoad),
            chapterBackward: #selector(UIViewController.viewDidLoad), toggleChromeAccessibility: #selector(UIViewController.viewDidLoad),
            horizontalSwipe: #selector(UIViewController.viewDidLoad), resetFlicker: #selector(UIViewController.viewDidLoad),
            toggleChrome: #selector(UIViewController.viewDidLoad), pageLeft: #selector(UIViewController.viewDidLoad),
            pageRight: #selector(UIViewController.viewDidLoad), previousChapter: #selector(UIViewController.viewDidLoad),
            nextChapter: #selector(UIViewController.viewDidLoad), retryLoading: #selector(UIViewController.viewDidLoad)),
        settings: settings, onUpdateFlicker: {}, onPDFPageReady: { _ in }
    )
    lazy var annotations: ReaderAnnotationsPresentation = ReaderAnnotationsPresentation(
        document: document, composition: composition, bookmarkStore: bookmarks,
        persistProgress: { [weak self] in self?.persisted += 1 },
        showChapter: { [weak self] in self?.showChapter($0) }, present: { _ in }
    )
    lazy var position: ReaderReadingPosition = ReaderReadingPosition(document: document, composition: composition,
        facts: { .init(chromeHidden: false, isPaginated: true, isLoading: false, layoutResult: nil) }, send: { _ in })
    lazy var prepared: ReaderPreparedPresentation = ReaderPreparedPresentation(document: document, settings: settings, renderer: renderer,
        store: PreparedReaderChapterStore(directory: archiveDirectory.appendingPathComponent("chapters")),
        stageObserver: nil, viewportIsCommitted: { false }, textIsLaidOut: { false }, send: { _ in })
    lazy var text: ReaderTextPresentation = ReaderTextPresentation(document: document, composition: composition, settings: settings,
        player: player, renderer: renderer, preparedPresentation: prepared, readingPosition: position,
        annotations: annotations, diagnostics: ReaderDiagnosticsPresentation(document: document, composition: composition),
        stageObserver: nil, applyColors: {}, showError: { XCTFail($0) }, completeLoading: {})
    var displayed: NSAttributedString { composition.textView.attributedText }
#endif

    init(chapters: [EbookFulltext.Chapter]) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        settings = AppSettings(defaults: defaults)
        bookmarks = BookmarkStore(defaults: defaults, storageKey: "bookmarks")
        archiveDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        renderer = PreparedChapterRenderer(store: PreparedChapterArchiveStore(directory: archiveDirectory))
        book = BookEntity(id: id, title: "Reader seam", bookmark: Data([1]),
            displayFilename: "seam.epub", addedAt: Date())
        player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
#if os(macOS)
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        document.currentBookId = id
#else
        document = ReaderBookDocument(book: book)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
#endif
        savedAnchors = anchorKeys.map { UserDefaults.standard.object(forKey: $0) }
        document.fulltext = EbookFulltext(jobId: id, bookTitle: book.title, bookAuthor: nil, chapters: chapters)
#if os(macOS)
        composition.configure()
#else
        composition.configure(isPaginatedMode: true, textDelegate: annotations,
            scrollDelegate: delegates, gestureDelegate: delegates)
#endif
    }

    static func chapter(_ text: String, index: Int = 1, name: String = "Chapter", html: String? = nil) -> EbookFulltext.Chapter {
        .init(index: index, name: name, text: text, html: html, css: nil, charCount: nil, segments: nil)
    }

    func showChapter(_ index: Int) {
        renderedIndices.append(index)
        document.selectedChapter = index
        text.showChapter(index)
    }

    func installTeardown(in test: XCTestCase) {
        test.addTeardownBlock { [self] in await finishCleanup() }
    }

    private func finishCleanup() async {
        await renderer.flush()
        cleanup()
    }

    private func cleanup() {
        player.stop()
        for (key, value) in zip(anchorKeys, savedAnchors) { UserDefaults.standard.set(value, forKey: key) }
        defaults.removePersistentDomain(forName: id)
        try? FileManager.default.removeItem(at: archiveDirectory)
    }
}

#if os(iOS)
@MainActor
private final class NativeReaderNoopDelegates: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {}
#endif
