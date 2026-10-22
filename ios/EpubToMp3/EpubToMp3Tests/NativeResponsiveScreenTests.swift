#if os(iOS) || os(macOS)
import XCTest
#if os(iOS)
import UIKit
#else
import AppKit
#endif
@testable import EpubToMp3

@MainActor
final class NativeResponsiveScreenTests: XCTestCase {
    var suiteName = ""
    var defaults: UserDefaults!
    var savedStandard: [String: Any] = [:]
    var savedWidget: [String: Any] = [:]
    let standardKeys = [AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey,
                                ReaderSessionState.currentlyReadingBookIDKey]
    let widgetKeys = ["currentlyPlayingBookId", "widget.nowPlayingChapterName", "widget.nowPlayingAuthor",
                              "widget.nowPlayingProgress", "widget.nowPlayingIsPlaying", "widget.nowPlayingPositionSeconds",
                              "widget.nowPlayingDurationSeconds", "widget.nowPlayingChapterRemainingSeconds",
                              "widget.nowPlayingBookRemainingSeconds", "widget.nowPlayingTotalChapters"]

    override func setUp() {
        super.setUp()
        suiteName = "responsive-screens-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        for key in standardKeys { savedStandard[key] = UserDefaults.standard.object(forKey: key) }
        let widget = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        for key in widgetKeys { savedWidget[key] = widget?.object(forKey: key) }
    }

    override func tearDown() {
        for key in standardKeys { restore(savedStandard[key], key: key, defaults: .standard) }
        if let widget = UserDefaults(suiteName: WidgetDataSync.appGroupID) {
            for key in widgetKeys { restore(savedWidget[key], key: key, defaults: widget) }
        }
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func restore(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    var book: BookEntity {
        BookEntity(id: suiteName, title: "A long book title that must remain readable on a compact screen",
                   author: "An author with a long descriptive name", bookmark: Data(),
                   displayFilename: "synthetic.epub", addedAt: Date(timeIntervalSince1970: 0))
    }

    #if os(iOS)







    func verifyBookDetail(size: CGSize, category: UIContentSizeCategory) throws {
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let controller = BookDetailScreenController(book: book, library: LibraryStore(defaults: defaults),
            settings: AppSettings(defaults: defaults), player: player,
            playerPresentation: PlayerPresentation(defaults: defaults))
        let host = UIViewController()
        host.addChild(controller)
        host.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: category), forChild: controller)
        host.view.addSubview(controller.view)
        controller.didMove(toParent: host)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        controller.view.frame = host.view.bounds
        host.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        let views = descendants(controller.view)
        let scroll = try XCTUnwrap(views.compactMap { $0 as? UIScrollView }.first)
        let buttons = views.compactMap { $0 as? UIButton }
        for text in [book.resolvedTitle, book.author ?? ""] {
            let label = try XCTUnwrap(views.compactMap { $0 as? UILabel }.first { $0.text == text })
            XCTAssertTrue(label.adjustsFontForContentSizeCategory, "Book metadata must follow Dynamic Type")
            XCTAssertEqual(label.numberOfLines, 0, "Book metadata must wrap")
        }
        for key in ["bookDetail.read", "bookDetail.listenStart", "bookDetail.download", "conversion.log"] {
            let title = L10n.string(key)
            let button = try XCTUnwrap(buttons.first { $0.title(for: .normal) == title || $0.configuration?.title == title })
            XCTAssertGreaterThanOrEqual(button.bounds.height, 44, "\(title), \(size), \(category)")
            XCTAssertLessThanOrEqual(button.bounds.width, scroll.bounds.width)
            if let label = button.titleLabel {
                let required = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
                XCTAssertLessThanOrEqual(required.height, label.bounds.height + 1, "Action title must not clip: \(title)")
            }
            let frame = button.convert(button.bounds, to: scroll)
            scroll.scrollRectToVisible(frame, animated: false)
            scroll.layoutIfNeeded()
            XCTAssertTrue(scroll.bounds.insetBy(dx: -1, dy: -1).contains(button.convert(button.bounds, to: scroll)),
                          "Action must be reachable by scrolling: \(title)")
        }
    }

    func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
    #else




    func captureLiveWindow(_ window: NSWindow, to url: URL) throws {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        window.backgroundColor.setFill()
        view.bounds.fill()
        bitmap.draw(in: view.bounds)
        image.unlockFocus()
        let flattened = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let png = try XCTUnwrap(flattened.representation(using: .png, properties: [:]))
        try png.write(to: url)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = url.lastPathComponent
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func childControllers(_ controller: NSViewController) -> [NSViewController] {
        controller.children + controller.children.flatMap(childControllers)
    }







    func verifyMacScrolling(_ controller: NSViewController, sizes: [NSSize], lastTitle: String) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: sizes[0]),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        for size in sizes {
            window.setContentSize(size)
            controller.view.layoutSubtreeIfNeeded()
            let views = descendants(controller.view)
            let scroll = try XCTUnwrap(views.compactMap { $0 as? NSScrollView }.first)
            let document = try XCTUnwrap(scroll.documentView)
            let buttons = views.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
            for button in buttons {
                let frame = button.convert(button.bounds, to: document)
                XCTAssertGreaterThan(button.bounds.height, 0)
                XCTAssertGreaterThanOrEqual(frame.minX, -1)
                XCTAssertLessThanOrEqual(frame.maxX, scroll.contentView.bounds.width + 1,
                                         "Control must fit resized window: \(button.title)")
            }
            let last = try XCTUnwrap(buttons.first { $0.title == lastTitle })
            document.scrollToVisible(last.convert(last.bounds, to: document))
            scroll.reflectScrolledClipView(scroll.contentView)
            XCTAssertTrue(scroll.contentView.bounds.insetBy(dx: -1, dy: -1)
                .contains(last.convert(last.bounds, to: document)), "Last action must be reachable by scrolling")
        }
    }

    func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    #endif
}
#endif
