#if os(macOS) && !targetEnvironment(simulator)
import AppKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MacReaderThemeTests: XCTestCase {
    func testLiveThemeChangesPaintCurrentSettingsWithoutMovingReader() async throws {
        let id = "live-reader-theme-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        let book = BookEntity(id: id, title: "Theme fixture", bookmark: Data([1]),
                              displayFilename: "theme.epub", addedAt: Date())
        defaults.set(try JSONEncoder().encode([book]), forKey: "library")
        let body = String(repeating: "A readable paragraph preserves its position.\n", count: 250)
        let payload = EbookFulltext(jobId: id, bookTitle: book.resolvedTitle, bookAuthor: nil,
            chapters: [.init(index: 1, name: "Theme chapter", text: body,
                html: "<html><body><p>Readable body.</p><p><a href='https://example.com'>Readable link</a></p><p>\(body)</p></body></html>",
                css: nil, charCount: nil, segments: nil)])
        LocalFulltextCache.save(payload, bookId: id)
        UserDefaults.standard.set(id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let settings = AppSettings(defaults: defaults)
        settings.readerTheme = .light
        settings.readerCustomColors = ((0.08, 0.10, 0.12), (0.92, 0.94, 0.96))
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer {
            player.stop()
            for (key, value) in zip(keys, previous) { UserDefaults.standard.set(value, forKey: key) }
            ReaderProgressStore.evict(bookId: id)
            LocalFulltextCache.evict(bookId: id)
            defaults.removePersistentDomain(forName: id)
        }
        let initialPositionCommitted = expectation(description: "Initial reader position committed")
        let controller = MacReaderViewController(
            library: LibraryStore(defaults: defaults, defaultsKey: "library"), settings: settings,
            player: player, bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            onClose: {}, initialPositionScheduler: { operation in
                DispatchQueue.main.async {
                    operation()
                    initialPositionCommitted.fulfill()
                }
            })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(controller.view)
        let text = try XCTUnwrap(views.compactMap { $0 as? MacReaderTextView }.first)
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        let toolbar = try XCTUnwrap(views.first { $0.accessibilityIdentifier() == "reader.toolbar" })
        for _ in 0..<200 {
            if text.string.contains("Readable link") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(text.string.contains("Readable link"))
        await fulfillment(of: [initialPositionCommitted], timeout: 5)
        // Persist a real page turn before changing colors. Theme application
        // must restore both this raw viewport and its listening anchor.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        let position = scroll.contentView.bounds.origin
        let playbackRatio = try XCTUnwrap(UserDefaults.standard.object(
            forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey) as? Double)
        let progress = try XCTUnwrap(ReaderProgressStore.read(bookId: id))
        XCTAssertGreaterThan(playbackRatio, 0)
        XCTAssertGreaterThan(progress.offsetFraction, 0)
        for theme in [ReaderTheme.dark, .sepia, .light, .custom] {
            settings.readerTheme = theme
            try await Task.sleep(nanoseconds: 50_000_000)
            let expected = settings.readerColors
            assertColor(text.backgroundColor, equals: expected.background)
            // Mixed body/link colors legitimately make NSTextView.textColor nil.
            assertColor(scroll.backgroundColor, equals: expected.background)
            assertColor(try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(toolbar.layer?.backgroundColor))),
                        equals: expected.background)
            let foreground = try XCTUnwrap(text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, "Body foreground must exist for \(theme.rawValue)")
            assertColor(foreground, equals: expected.foreground)
            if theme != .light || settings.readerOverrideColours {
                let link = try XCTUnwrap(text.linkTextAttributes?[.foregroundColor] as? NSColor, "Link foreground must exist for \(theme.rawValue)")
                assertColor(link, equals: expected.link)
            } else {
                XCTAssertTrue(text.linkTextAttributes?.isEmpty != false,
                              "Original light-mode link colors must remain authored")
            }
            XCTAssertEqual(scroll.contentView.bounds.origin.y, position.y, accuracy: 0.5,
                           "Color-only changes must preserve the visible passage")
            XCTAssertEqual(UserDefaults.standard.double(forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey),
                           playbackRatio, accuracy: 0.000_001,
                           "Theme changes must preserve the page used by Play")
            // Compare saved fractions using the same half-point allowance as
            // the raw viewport; semantic appearance may round the laid-out height.
            let fractionTolerance = Double(0.5 / max(1, text.frame.height - scroll.contentView.bounds.height))
            XCTAssertEqual(ReaderProgressStore.read(bookId: id)?.offsetFraction ?? -1,
                           progress.offsetFraction, accuracy: fractionTolerance,
                           "Theme changes must preserve the saved passage within half a point")
            if let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                    attachment.name = "mac-reader-theme-\(theme.rawValue)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    func testOriginalLightThemePreservesAuthoredBodyAndLinkColors() throws {
        let suite = "authored-reader-colors-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.readerTheme = .light
        settings.readerOverrideColours = false
        let text = NSTextView()
        let content = NSMutableAttributedString(string: "Body Link", attributes: [.foregroundColor: NSColor.red])
        content.addAttributes([.foregroundColor: NSColor.green,
                               .link: URL(string: "https://example.com")!],
                              range: NSRange(location: 5, length: 4))
        content.addAttribute(.backgroundColor, value: NSColor.yellow, range: NSRange(location: 0, length: 4))
        text.textStorage?.setAttributedString(content)
        MacReaderTheme.apply(settings: settings, surface: NSView(), scrollView: NSScrollView(), textView: text)
        assertColor(try XCTUnwrap(text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor),
                    equals: .red)
        assertColor(try XCTUnwrap(text.textStorage?.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor),
                    equals: .green)
        assertColor(try XCTUnwrap(text.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor),
                    equals: .yellow)
        XCTAssertTrue(text.linkTextAttributes?.isEmpty != false)
    }

    private func assertColor(_ actual: NSColor, equals expected: NSColor,
                             file: StaticString = #filePath, line: UInt = #line) {
        let a = actual.usingColorSpace(.deviceRGB)
        let b = expected.usingColorSpace(.deviceRGB)
        XCTAssertNotNil(a, file: file, line: line)
        XCTAssertNotNil(b, file: file, line: line)
        XCTAssertEqual(a?.redComponent ?? -1, b?.redComponent ?? -2, accuracy: 0.005, file: file, line: line)
        XCTAssertEqual(a?.greenComponent ?? -1, b?.greenComponent ?? -2, accuracy: 0.005, file: file, line: line)
        XCTAssertEqual(a?.blueComponent ?? -1, b?.blueComponent ?? -2, accuracy: 0.005, file: file, line: line)
        XCTAssertEqual(a?.alphaComponent ?? -1, b?.alphaComponent ?? -2, accuracy: 0.005, file: file, line: line)
    }

    func testLightThemeMakesReaderSurfaceOpaqueAndReadable() throws {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.readerTheme = .light
        let surface = NSView()
        let scrollView = NSScrollView()
        let textView = NSTextView()
        let toolbar = NSView()
        let title = NSTextField(labelWithString: "Chapter 10: Strider")

        MacReaderTheme.apply(
            settings: settings,
            surface: surface,
            scrollView: scrollView,
            textView: textView,
            toolbar: toolbar,
            labels: [title]
        )

        XCTAssertTrue(scrollView.drawsBackground)
        XCTAssertTrue(textView.drawsBackground)
        assertColor(textView.backgroundColor, equals: settings.readerColors.background)
        assertColor(try XCTUnwrap(textView.textColor), equals: settings.readerColors.foreground)
        assertColor(scrollView.backgroundColor, equals: settings.readerColors.background)
        assertColor(try XCTUnwrap(title.textColor), equals: settings.readerColors.foreground)
        assertColor(try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(toolbar.layer?.backgroundColor))), equals: settings.readerColors.background)
    }

    func testAutoThemeResolvesSurfaceAndTitleUsingOneAppearance() throws {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.readerTheme = .auto
        let surface = NSView()
        let parent = NSView()
        parent.appearance = NSAppearance(named: .aqua)
        parent.addSubview(surface)
        surface.appearance = NSAppearance(named: .darkAqua)
        let title = NSTextField(labelWithString: "Chapter 10: Strider")

        MacReaderTheme.apply(
            settings: settings,
            surface: surface,
            scrollView: NSScrollView(),
            textView: NSTextView(),
            labels: [title]
        )

        assertColor(try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(surface.layer?.backgroundColor))), equals: .white)
        assertColor(try XCTUnwrap(title.textColor), equals: .black)
    }

    func testAutoThemeResolvesDarkAquaToDarkSurfaceAndReadableText() throws {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.readerTheme = .auto
        let surface = NSView()
        let parent = NSView()
        parent.appearance = NSAppearance(named: .darkAqua)
        parent.addSubview(surface)
        surface.appearance = NSAppearance(named: .aqua)
        let scrollView = NSScrollView()
        let textView = NSTextView()
        let toolbar = NSView()
        let title = NSTextField(labelWithString: "Chapter 10: Strider")

        MacReaderTheme.apply(
            settings: settings,
            surface: surface,
            scrollView: scrollView,
            textView: textView,
            toolbar: toolbar,
            labels: [title]
        )

        let backgroundRed = textView.backgroundColor.usingColorSpace(.deviceRGB)?.redComponent ?? 1
        let foregroundRed = textView.textColor?.usingColorSpace(.deviceRGB)?.redComponent ?? 0
        XCTAssertLessThan(backgroundRed, 0.5, "Auto dark mode must not leave a white reader surface")
        XCTAssertGreaterThan(foregroundRed, 0.7, "Auto dark mode must keep reader text readable")
        XCTAssertEqual(scrollView.backgroundColor, textView.backgroundColor)
        assertColor(try XCTUnwrap(title.textColor), equals: textView.textColor ?? .clear)
    }

    func testEveryReaderThemeProducesOpaqueContrastingMacOSColours() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)

        for theme in ReaderTheme.allCases {
            settings.readerTheme = theme
            let surface = NSView()
            let parent = NSView()
            parent.appearance = NSAppearance(named: theme == .auto ? .darkAqua : .aqua)
            parent.addSubview(surface)
            let textView = NSTextView()

            MacReaderTheme.apply(
                settings: settings,
                surface: surface,
                scrollView: NSScrollView(),
                textView: textView
            )

            let background = textView.backgroundColor.usingColorSpace(.deviceRGB)
            let foreground = textView.textColor?.usingColorSpace(.deviceRGB)
            XCTAssertNotNil(background, "\(theme.rawValue) must provide a readable background")
            XCTAssertNotNil(foreground, "\(theme.rawValue) must provide readable text")
            XCTAssertGreaterThan(
                abs((background?.redComponent ?? 0) - (foreground?.redComponent ?? 0)),
                0.15,
                "\(theme.rawValue) must keep foreground and background visually distinct"
            )
        }
    }
}
#endif
