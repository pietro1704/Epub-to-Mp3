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
        VStack(alignment: .leading, spacing: 0) {
            Text(chapter.displayTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, margin)
                .padding(.top, 24)
                .padding(.bottom, 8)
            if let attributed {
                AttributedPageView(
                    attributed: attributed,
                    width: columnWidth,
                    scrollable: false,
                    onLinkTap: onLinkTap
                )
                .padding(.horizontal, margin)
                .padding(.bottom, 16)
            } else {
                // Placeholder height while the HTML renders so the lazy
                // stack doesn't collapse to zero and snap-scroll.
                Color.clear.frame(height: 120)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .task(id: renderKey) {
            // Render off the synchronous body path. `EpubHtmlRenderer.render`
            // is main-thread (WebKit importer) but cheap enough per chapter;
            // gating on `renderKey` ensures one render per identity change.
            guard lastRenderKey != renderKey else { return }
            lastRenderKey = renderKey
            attributed = makeAttributed()
        }
        .onAppear { onAppearChapter?() }
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
