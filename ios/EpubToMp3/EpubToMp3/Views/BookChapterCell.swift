import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// One chapter cell in the continuous full-book scroll. Rendered lazily
/// inside `ReaderView.continuousBookScroll`'s `LazyVStack`, so its HTML is
/// only parsed into an `NSAttributedString` when the cell scrolls near the
/// viewport — a large book never pays the cost of rendering every chapter
/// up front.
///
/// Mirrors the single-chapter scroll renderer: prefers the EPUB HTML
/// `AttributedString` (carrying CSS fonts / colours / italics) and falls
/// back to a plain-text wrapper with the user's font + spacing when the
/// chapter has no HTML payload. The text is drawn by `AttributedPageView`
/// (`scrollable: false`, intrinsic height) — the same TextKit view the
/// paginator measures against — so typography matches the paginated mode.
/// Process-wide cache of already-parsed chapter attributed strings, keyed by
/// the same identity string (`renderKey`) that gates a re-render. Scroll mode
/// hosts every cell in a `LazyVStack`, so a cell that scrolls out of the
/// viewport is DESTROYED — its `@State attributed` is lost. When the user
/// scrolls it back, a cache-less cell blanked to its `Color.clear` placeholder
/// and re-ran `EpubHtmlRenderer.render` (50–200 ms, main-thread WebKit
/// importer): the chapter text visibly vanished, then repainted a frame later.
/// That is the "flicker no modo rolagem" the user saw. With this cache a
/// recycled cell paints the previously-parsed text synchronously in `body`,
/// so no blank frame and no re-parse ever happen for a chapter already seen.
///
/// `NSCache` bounds memory automatically (evicts under pressure) and is
/// thread-safe; all reads/writes here are on the main actor anyway.
@MainActor
enum BookChapterRenderCache {
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let c = NSCache<NSString, NSAttributedString>()
        // Cap by count so a huge book can't pin every chapter forever; the
        // working set during a scroll is only the handful of on/near-screen
        // cells, so 64 comfortably covers scroll-back without unbounded growth.
        c.countLimit = 64
        return c
    }()

    static func value(for key: String) -> NSAttributedString? {
        cache.object(forKey: key as NSString)
    }

    static func store(_ value: NSAttributedString, for key: String) {
        cache.setObject(value, forKey: key as NSString)
    }

    /// Test hook: clear so a regression test starts from a known-empty state.
    static func removeAll() { cache.removeAllObjects() }
}

struct BookChapterCell: View {
    let chapter: EbookFulltext.Chapter
    let settings: AppSettings
    let fontDirectoryURL: URL?
    let columnWidth: CGFloat
    let margin: CGFloat
    let fontSize: CGFloat
    let lineSpacing: Double
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    var onLinkTap: ((URL) -> Bool)? = nil
    /// Fired once when the cell first appears, so the host can mirror the
    /// active chapter (TOC highlight, position persistence).
    var onAppearChapter: (() -> Void)? = nil

    /// Re-render whenever the chapter id or any setting the renderer reads
    /// changes — same identity contract as `ReaderView.renderedAttributedKey`.
    private var renderKey: String {
        [
            chapter.id,
            settings.readerFontFamily.rawValue,
            String(format: "%.0f", settings.readerPointSize),
            settings.readerTheme.rawValue,
            settings.readerOverrideColours.description,
            settings.readerBoldOverride.description,
            settings.readerSuppressItalic.description,
            settings.readerTextAlignment.rawValue,
            String(format: "%.2f", lineSpacing),
            String(format: "%.0f", fontSize),
        ].joined(separator: "|")
    }

    @State private var attributed: NSAttributedString?
    @State private var lastRenderKey: String?

    var body: some View {
        // Prefer the live @State render, but fall back to the process cache so
        // a cell recycled by the LazyVStack paints its previously-parsed text
        // synchronously on the very first frame — no blank placeholder, no
        // re-parse flicker. The cache read is keyed on the same `renderKey`
        // that gates a re-render, so a cache hit is always identity-correct.
        let displayed = attributed ?? BookChapterRenderCache.value(for: renderKey)
        return VStack(alignment: .leading, spacing: 0) {
            Text(chapter.displayTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, margin)
                .padding(.top, 24)
                .padding(.bottom, 8)
            if let attributed = displayed {
                AttributedPageView(
                    attributed: attributed,
                    width: columnWidth,
                    scrollable: false,
                    onLinkTap: onLinkTap
                )
                .padding(.horizontal, margin)
                .padding(.bottom, 16)
            } else {
                // Placeholder sized to the chapter's ESTIMATED rendered height
                // while the HTML parses. A fixed 120 pt collapsed every cell to
                // a stub, so a fast scroll showed white bands that then jumped
                // to full height when the text landed (the "pisca branco ao
                // rolar rápido" flicker). Reserving an estimate keeps the scroll
                // metrics stable: the text fills the reserved space instead of
                // shoving the rest of the book down.
                Color.clear.frame(height: estimatedTextHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .task(id: renderKey) {
            // Render off the synchronous body path. `EpubHtmlRenderer.render`
            // is main-thread (WebKit importer) but cheap enough per chapter;
            // gating on `renderKey` ensures one render per identity change.
            guard lastRenderKey != renderKey else { return }
            // Cache hit: a cell recycled by the LazyVStack (or reused after a
            // benign setting echo) already has this exact render cached. Paint
            // it without re-parsing — this is the path that eliminates the
            // scroll-mode flicker for chapters the user has already scrolled
            // past once. No `.staleSlicePushed` is recorded because nothing
            // repaints: `attributed` was already showing the cached value via
            // the `body` fallback, so this assignment is a no-op on screen.
            if let cached = BookChapterRenderCache.value(for: renderKey) {
                lastRenderKey = renderKey
                attributed = cached
                return
            }
            // A RE-render of a cell that already had content (lastRenderKey
            // non-nil) while the chapter id is unchanged is a scroll-mode
            // flicker: the cell re-parses and the text visibly repaints.
            #if os(iOS)
            if lastRenderKey != nil, lastRenderKey?.hasPrefix(chapter.id + "|") == true {
                FlickerProbe.shared.record(.staleSlicePushed)
            }
            #endif
            lastRenderKey = renderKey
            let rendered = makeAttributed()
            BookChapterRenderCache.store(rendered, for: renderKey)
            attributed = rendered
        }
        .onAppear { onAppearChapter?() }
    }

    /// Rough estimate of the chapter's rendered text height, used to size the
    /// placeholder so a not-yet-rendered cell reserves the right amount of
    /// space (no white-band flash + scroll jump). Approximates characters per
    /// line from the column width and font size, then multiplies the line
    /// count by an estimated line height. Clamped so a tiny chapter still gets
    /// a sensible minimum and a huge one doesn't reserve an absurd height.
    private var estimatedTextHeight: CGFloat {
        let chars = CGFloat(max(chapter.charCount ?? chapter.text.count, 1))
        // ~1.9 pt of width per character at the body size is a decent average
        // for proportional fonts; avoid div-by-zero on a zero column.
        let avgCharWidth = max(fontSize * 0.5, 1)
        let charsPerLine = max(columnWidth / avgCharWidth, 1)
        let lines = (chars / charsPerLine).rounded(.up)
        let lineHeight = fontSize + CGFloat(lineSpacing)
        let body = lines * lineHeight
        // Title + paddings already added around the body in `body`.
        return min(max(body, 120), 20_000)
    }

    private func makeAttributed() -> NSAttributedString {
        #if canImport(UIKit) || canImport(AppKit)
        if let html = chapter.html, !html.isEmpty,
           let rendered = EpubHtmlRenderer.render(
                html: html, css: chapter.css, settings: settings,
                fontDirectoryURL: fontDirectoryURL
           ) {
            return NSAttributedString(rendered)
        }
        let plain = EbookFulltext.Chapter.stripLeadingArtifact(
            EbookFulltext.Chapter.collapseHardWraps(chapter.text)
        )
        let para = NSMutableParagraphStyle()
        para.lineSpacing = CGFloat(lineSpacing)
        para.alignment = settings.readerTextAlignment == .justified ? .justified : .left
        let font: PlatformFontType
        #if canImport(UIKit)
        switch settings.readerFontFamily {
        case .sans: font = .systemFont(ofSize: fontSize)
        case .serif:
            let d = UIFont.systemFont(ofSize: fontSize).fontDescriptor.withDesign(.serif)
                ?? UIFont.systemFont(ofSize: fontSize).fontDescriptor
            font = UIFont(descriptor: d, size: fontSize)
        case .mono: font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        #else
        switch settings.readerFontFamily {
        case .sans: font = .systemFont(ofSize: fontSize)
        case .serif: font = NSFont(name: "Times New Roman", size: fontSize) ?? .systemFont(ofSize: fontSize)
        case .mono: font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        #endif
        return NSAttributedString(string: plain, attributes: [
            .font: font,
            .paragraphStyle: para,
        ])
        #else
        return NSAttributedString(string: chapter.text)
        #endif
    }
}

#if canImport(UIKit)
private typealias PlatformFontType = UIFont
#elseif canImport(AppKit)
private typealias PlatformFontType = NSFont
#endif
