#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderThemeAppearanceTests: XCTestCase {
    func testMainReaderRootUsesSemanticPaletteAndKeepsNativeMaterialAcrossLightAndDark() throws {
        let id = "main-reader-semantic-theme-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let settings = AppSettings(defaults: defaults)
        let library = LibraryStore(defaults: defaults, defaultsKey: "library")
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let root = MainReaderScreenController(library: library, settings: settings, player: player,
            playerPresentation: PlayerPresentation(defaults: defaults),
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            onBrowseLibrary: nil, sessionDefaults: defaults)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        defer {
            window.isHidden = true
            window.rootViewController = nil
            defaults.removePersistentDomain(forName: id)
        }
        window.rootViewController = root
        window.makeKeyAndVisible()
        var materialOpacity: Bool?
        var materialAlpha: CGFloat?
        var originalMaterialEffect: UIVisualEffect?
        var originalMaterialView: AdaptiveMaterialView?
        for (theme, nativeStyle) in [(ReaderTheme.light, UIUserInterfaceStyle.light), (.dark, .dark)] {
            // The chosen reading appearance must work independently of the surrounding system.
            window.overrideUserInterfaceStyle = nativeStyle == .light ? .dark : .light
            settings.readerTheme = theme
            root.update(library: library, settings: settings, onBrowseLibrary: nil)
            root.view.layoutIfNeeded()
            let expected = UIColor.systemBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: nativeStyle))
            assertColor(root.view.backgroundColor, equals: expected, traits: root.view.traitCollection)
            let navigation: UINavigationBar = try XCTUnwrap(descendant(in: root.view))
            XCTAssertTrue(navigation.isTranslucent, "Both appearances must retain native translucent reader chrome.")
            let appearance = navigation.standardAppearance
            XCTAssertNil(appearance.backgroundEffect, "The existing native material behind the bar owns the blur.")
            XCTAssertEqual(appearance.backgroundColor?.cgColor.alpha ?? 0, 0, accuracy: 0.001)
            let material: AdaptiveMaterialView = try XCTUnwrap(descendant(in: root.view))
            try assertNativeMaterial(material.effect, original: originalMaterialEffect)
            if let originalMaterialView {
                XCTAssertTrue(material === originalMaterialView, "Appearance changes must retain the native material surface.")
            }
            originalMaterialView = material
            originalMaterialEffect = material.effect
            XCTAssertEqual(material.backgroundColor?.cgColor.alpha ?? 0, 0, accuracy: 0.001)
            XCTAssertFalse(material.isUserInteractionEnabled)
            if let materialOpacity, let materialAlpha {
                XCTAssertEqual(material.isOpaque, materialOpacity, "Changing appearance must preserve the same native transparency configuration.")
                XCTAssertEqual(material.alpha, materialAlpha, accuracy: 0.001)
            }
            materialOpacity = material.isOpaque
            materialAlpha = material.alpha
        }
        settings.readerTheme = .custom
        settings.readerCustomColors = ((0.14, 0.20, 0.27), (0.91, 0.89, 0.82))
        root.update(library: library, settings: settings, onBrowseLibrary: nil)
        root.view.layoutIfNeeded()
        assertColor(root.view.backgroundColor, equals: UIColor(red: 0.14, green: 0.20, blue: 0.27, alpha: 1),
                    traits: root.view.traitCollection)
        settings.readerCustomColors = ((0.93, 0.86, 0.73), (0.14, 0.10, 0.05))
        root.update(library: library, settings: settings, onBrowseLibrary: nil)
        root.view.layoutIfNeeded()
        assertColor(root.view.backgroundColor, equals: UIColor(red: 0.93, green: 0.86, blue: 0.73, alpha: 1),
                    traits: root.view.traitCollection)
    }

    func testMiniPlayerRetainsTheSameNativeMaterialInLightAndDark() throws {
        let playerBar = MiniPlayerBarUIKitView(frame: CGRect(x: 0, y: 0, width: 320, height: 60))
        let material: AdaptiveMaterialView = try XCTUnwrap(playerBar.subviews.first {
            $0.accessibilityIdentifier == "miniPlayer.pillMaterial"
        } as? AdaptiveMaterialView)
        let opaque = material.isOpaque
        let alpha = material.alpha
        let originalEffect = try XCTUnwrap(material.effect)
        for style in [UIUserInterfaceStyle.light, .dark] {
            playerBar.overrideUserInterfaceStyle = style
            playerBar.layoutIfNeeded()
            try assertNativeMaterial(material.effect, original: originalEffect)
            XCTAssertEqual(material.backgroundColor?.cgColor.alpha ?? 0, 0, accuracy: 0.001)
            XCTAssertEqual(material.isOpaque, opaque)
            XCTAssertEqual(material.alpha, alpha, accuracy: 0.001)
        }
    }

    private func assertNativeMaterial(_ candidate: UIVisualEffect?, original: UIVisualEffect?,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let effect = try XCTUnwrap(candidate, file: file, line: line)
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let glass = try XCTUnwrap(effect as? UIGlassEffect, file: file, line: line)
            XCTAssertFalse(glass.isInteractive, file: file, line: line)
            XCTAssertNil(glass.tintColor, file: file, line: line)
            if let original {
                let previous = try XCTUnwrap(original as? UIGlassEffect, file: file, line: line)
                XCTAssertEqual(glass.isInteractive, previous.isInteractive, file: file, line: line)
                XCTAssertEqual(glass.tintColor, previous.tintColor, file: file, line: line)
            }
            // UIKit copies glass effects even on consecutive property reads.
            // Preserve configuration and surface identity, not getter identity.
            return
        }
#endif
        XCTAssertNotNil(effect as? UIBlurEffect, "Legacy UIKit must retain native blur.", file: file, line: line)
        if let original {
            XCTAssertTrue(effect === original, "Legacy material identity must survive appearance changes.", file: file, line: line)
        }
    }

    func testInitialDarkReaderUsesOnePaletteUnderLightSystemAppearance() async throws {
        try await withReader(theme: .dark, systemStyle: .light) { reader, _, text, viewport, settings in
            self.assertPalette(settings.readerTheme.previewColors, reader: reader, text: text, viewport: viewport)
            self.assertRenderedPalette(settings.readerTheme.previewColors, in: text)
        }
    }

    func testInitialLightReaderPreservesAuthorForegroundUnderDarkSystemAppearance() async throws {
        try await withReader(theme: .light, systemStyle: .dark) { reader, _, text, viewport, _ in
            let lightTraits = UITraitCollection(userInterfaceStyle: .light)
            self.assertPalette((UIColor.systemBackground.resolvedColor(with: lightTraits), UIColor.label.resolvedColor(with: lightTraits)),
                               reader: reader, text: text, viewport: viewport)
            let index = try XCTUnwrap(text.attributedText.string.range(of: "Author red"))
            let offset = NSRange(index, in: text.attributedText.string).location
            let foreground = try XCTUnwrap(text.attributedText.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? UIColor)
            self.assertColor(foreground, equals: .red, traits: text.traitCollection)
            XCTAssertNotNil(self.link(in: text.attributedText), "Theme application must retain EPUB links.")
        }
    }

    func testWarmThemesUseTheSameBackgroundForRenderedRunsAndNativePage() async throws {
        for theme in [ReaderTheme.sepia, .parchment, .paper] {
            try await withReader(theme: theme, systemStyle: .dark) { reader, _, text, viewport, settings in
                self.assertPalette(settings.readerTheme.previewColors, reader: reader, text: text, viewport: viewport)
                self.assertRenderedPalette(settings.readerTheme.previewColors, in: text)
            }
        }
    }

    func testCustomReaderUsesSavedColoursAndRefreshesChangedRGBValues() async throws {
        try await withReader(theme: .custom, systemStyle: .light) { reader, window, text, viewport, settings in
            let initial: (background: UIColor, foreground: UIColor) = (
                UIColor(red: 0.08, green: 0.12, blue: 0.18, alpha: 1),
                UIColor(red: 0.93, green: 0.88, blue: 0.73, alpha: 1))
            self.assertPalette(initial, reader: reader, text: text, viewport: viewport)
            self.assertRenderedPalette(initial, in: text)
            let frame = viewport.frame
            let offset = viewport.contentOffset
            let sheet = try await self.openSettings(reader)
            settings.readerCustomColors = ((0.92, 0.87, 0.72), (0.12, 0.09, 0.04))
            // Exercise the settings sheet's public change callback used by its controls.
            sheet.onChange?()
            try await Task.sleep(nanoseconds: 250_000_000)
            reader.view.layoutIfNeeded()
            let changed: (background: UIColor, foreground: UIColor) = (
                UIColor(red: 0.92, green: 0.87, blue: 0.72, alpha: 1),
                UIColor(red: 0.12, green: 0.09, blue: 0.04, alpha: 1))
            self.assertPalette(changed, reader: reader, text: text, viewport: viewport)
            self.assertRenderedPalette(changed, in: text)
            XCTAssertEqual(viewport.frame, frame)
            XCTAssertEqual(viewport.contentOffset.y, offset.y, accuracy: 0.5)
            XCTAssertTrue(text.window === window)
        }
    }

    func testThemeSelectionUpdatesTheMountedReaderWithoutMovingItsViewport() async throws {
        let bookID = "reader-theme-page-progress-\(UUID().uuidString)"
        try await withReader(theme: .light, systemStyle: .light, bookID: bookID) { reader, _, text, viewport, settings in
            let turn = NSSelectorFromString("turnPageRight")
            XCTAssertTrue(reader.responds(to: turn))
            reader.perform(turn)
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                reader.view.layoutIfNeeded()
                let hasPageCurl = reader.view.subviews.contains { $0.accessibilityIdentifier == "reader.pageCurl" }
                if viewport.contentOffset.y > 0, !hasPageCurl, viewport.transform.isIdentity { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertGreaterThan(viewport.contentOffset.y, 0, "The test must exercise an explicit page turn before changing theme.")
            XCTAssertFalse(reader.view.subviews.contains { $0.accessibilityIdentifier == "reader.pageCurl" })
            XCTAssertTrue(viewport.transform.isIdentity)
            let frame = viewport.frame
            let offset = viewport.contentOffset
            let pageRatio = UserDefaults.standard.double(forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
            let progress = try XCTUnwrap(ReaderProgressStore.read(bookId: bookID))
            XCTAssertGreaterThan(pageRatio, 0, "The playback bridge must identify the visible page before changing theme.")
            XCTAssertGreaterThan(progress.offsetFraction, 0)
            let sheet = try await self.openSettings(reader)
            let themes = ReaderTheme.allCases.filter { $0 != .custom }
            let row = try XCTUnwrap(themes.firstIndex(of: .dark))
            sheet.tableView(sheet.tableView, didSelectRowAt: IndexPath(row: row, section: 0))
            try await Task.sleep(nanoseconds: 250_000_000)
            reader.view.layoutIfNeeded()
            XCTAssertEqual(settings.readerTheme, .dark)
            self.assertPalette(settings.readerTheme.previewColors, reader: reader, text: text, viewport: viewport)
            self.assertRenderedPalette(settings.readerTheme.previewColors, in: text)
            XCTAssertEqual(viewport.frame, frame, "A colour-only choice must retain the reader viewport geometry.")
            XCTAssertEqual(viewport.contentOffset.y, offset.y, accuracy: 0.5)
            XCTAssertEqual(UserDefaults.standard.double(forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey),
                           pageRatio, accuracy: 0.0001, "Repainting must not reset the playback bridge to chapter start.")
            let restored = try XCTUnwrap(ReaderProgressStore.read(bookId: bookID))
            XCTAssertEqual(restored.chapterIndex, progress.chapterIndex)
            XCTAssertEqual(restored.offsetFraction, progress.offsetFraction, accuracy: 0.0001)
            XCTAssertEqual(restored.characterOffset, progress.characterOffset)
        }
    }

    private func openSettings(_ reader: BookOpenScreenController) async throws -> ReaderSettingsScreenController {
        let action = NSSelectorFromString("presentReaderSettings")
        XCTAssertTrue(reader.responds(to: action))
        reader.perform(action)
        try await Task.sleep(nanoseconds: 350_000_000)
        let navigation = try XCTUnwrap(reader.presentedViewController as? UINavigationController)
        return try XCTUnwrap(navigation.topViewController as? ReaderSettingsScreenController)
    }

    private func assertPalette(_ colors: (background: UIColor, foreground: UIColor), reader: BookOpenScreenController,
                               text: UITextView, viewport: UIScrollView, file: StaticString = #filePath, line: UInt = #line) {
        for view in [reader.view!, viewport, text] {
            assertColor(view.backgroundColor, equals: colors.background, traits: view.traitCollection, file: file, line: line)
        }
        XCTAssertNotNil(link(in: text.attributedText), "Theme application must retain EPUB links.", file: file, line: line)
    }

    private func assertRenderedPalette(_ colors: (background: UIColor, foreground: UIColor), in text: UITextView,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let contents = text.attributedText!
        let range = (contents.string as NSString).range(of: "Author red")
        XCTAssertNotEqual(range.location, NSNotFound, file: file, line: line)
        guard range.location != NSNotFound else { return }
        assertColor(contents.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor,
                    equals: colors.foreground, traits: text.traitCollection, file: file, line: line)
        // A transparent run is valid: its page surface supplies the same background.
        if let background = contents.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? UIColor {
            assertColor(background, equals: colors.background, traits: text.traitCollection, file: file, line: line)
        }
    }

    private func assertColor(_ actual: UIColor?, equals expected: UIColor, traits: UITraitCollection,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else { return XCTFail("The native reader must have an explicit opaque colour.", file: file, line: line) }
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var er: CGFloat = 0, eg: CGFloat = 0, eb: CGFloat = 0, ea: CGFloat = 0
        XCTAssertTrue(actual.resolvedColor(with: traits).getRed(&ar, green: &ag, blue: &ab, alpha: &aa), file: file, line: line)
        XCTAssertTrue(expected.resolvedColor(with: traits).getRed(&er, green: &eg, blue: &eb, alpha: &ea), file: file, line: line)
        for (value, target) in zip([ar, ag, ab, aa], [er, eg, eb, ea]) {
            XCTAssertEqual(value, target, accuracy: 0.002, file: file, line: line)
        }
    }

    private func link(in text: NSAttributedString) -> Any? {
        var found: Any?
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if let value { found = value; stop.pointee = true }
        }
        return found
    }

    private func withReader(theme: ReaderTheme, systemStyle: UIUserInterfaceStyle, bookID: String? = nil,
                            verify: (BookOpenScreenController, UIWindow, UITextView, UIScrollView, AppSettings) async throws -> Void) async throws {
        let id = bookID ?? "reader-theme-appearance-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let keys = [ReaderSessionState.currentlyReadingBookIDKey, AudioPlayer.currentBookIDDefaultsKey,
                    AudioPlayer.currentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey, AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey, "readerWarmBookIDs.v1"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        let settings = AppSettings(defaults: defaults)
        settings.readerTheme = theme
        settings.readerLayout = .paginated
        settings.readerCustomColors = ((0.08, 0.12, 0.18), (0.93, 0.88, 0.73))
        let html = "<p style='color:#ff0000'>Author red <a href='#note'>internal note</a>.</p><p>" +
            String(repeating: "A traveller followed the river through a quiet valley. ", count: 120) + "</p>"
        let chapter = EbookFulltext.Chapter(index: 1, name: "Palette chapter", text: "Author red internal note.",
                                            html: html, css: nil, charCount: nil, segments: nil)
        LocalFulltextCache.save(EbookFulltext(jobId: id, bookTitle: "Palette regression", bookAuthor: nil, chapters: [chapter]), bookId: id)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let reader = BookOpenScreenController(book: BookEntity(id: id, title: "Palette regression", bookmark: Data(),
            displayFilename: "palette.epub", addedAt: Date()), library: LibraryStore(defaults: defaults, defaultsKey: "library"),
            settings: settings, bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"), player: player,
            sessionDefaults: defaults, deferInitialReaderGestures: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        window.overrideUserInterfaceStyle = systemStyle
        defer {
            window.isHidden = true
            window.rootViewController = nil
            player.stop()
            LocalFulltextCache.evict(bookId: id)
            ReaderProgressStore.evict(bookId: id)
            defaults.removePersistentDomain(forName: id)
            for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) }
        }
        window.rootViewController = reader
        window.makeKeyAndVisible()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            reader.view.layoutIfNeeded()
            if !reader.isLoadingBookContent, let text: UITextView = descendant(in: reader.view), text.attributedText.length > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let text: UITextView = try XCTUnwrap(descendant(in: reader.view))
        XCTAssertFalse(reader.isLoadingBookContent)
        XCTAssertTrue(text.attributedText.string.contains("Author red"))
        var parent = text.superview
        while parent != nil, !(parent is UIScrollView) { parent = parent?.superview }
        let viewport = try XCTUnwrap(parent as? UIScrollView)
        try await verify(reader, window, text, viewport, settings)
    }

    private func descendant<T: UIView>(in view: UIView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant(in: $0) as T? }.first
    }
}
#endif
