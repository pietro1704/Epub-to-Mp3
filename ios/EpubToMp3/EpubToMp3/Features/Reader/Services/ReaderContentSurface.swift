#if os(iOS)
import PDFKit
import UIKit

/// Owns which native content surface is mounted in the reader.
///
/// TextKit layout, delegates, and reading interactions remain with the book
/// flow. This module only makes the mutually exclusive text, comic, and PDF
/// mounting rules explicit so an import can safely switch surfaces.
@MainActor
final class ReaderContentSurface {
    enum Kind: Equatable {
        case text
        case comic
        case pdf
    }

    private let textView: UITextView
    private let comicPageImageView: UIImageView
    private let readerView: UIView
    private let scrollView: UIScrollView
    private var pdfView: PDFView?
    private var pdfLoadingIndicator: UIActivityIndicatorView?
    private var pdfPreparationTask: Task<Void, Never>?
    private var pdfMountGeneration = 0

    private(set) var textLeadingConstraint: NSLayoutConstraint!
    private(set) var textTrailingConstraint: NSLayoutConstraint!
    private(set) var textWidthConstraint: NSLayoutConstraint!
    private(set) var paginatedTextHeightConstraint: NSLayoutConstraint!
    private(set) var scrollingTextHeightConstraint: NSLayoutConstraint!
    private var textConstraints: [NSLayoutConstraint] = []
    private var comicConstraints: [NSLayoutConstraint] = []

    private(set) var kind: Kind = .text

    var isDisplayingText: Bool { kind == .text }
    var isDisplayingComic: Bool { kind == .comic }

    init(
        readerView: UIView,
        scrollView: UIScrollView,
        textView: UITextView,
        comicPageImageView: UIImageView
    ) {
        self.readerView = readerView
        self.scrollView = scrollView
        self.textView = textView
        self.comicPageImageView = comicPageImageView
    }

    func install() {
        textView.translatesAutoresizingMaskIntoConstraints = false
        comicPageImageView.translatesAutoresizingMaskIntoConstraints = false
        comicPageImageView.contentMode = .scaleAspectFit
        comicPageImageView.clipsToBounds = true
        comicPageImageView.backgroundColor = .clear
        scrollView.addSubview(textView)
        scrollView.addSubview(comicPageImageView)

        textLeadingConstraint = textView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor)
        textTrailingConstraint = textView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor)
        textWidthConstraint = textView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        textConstraints = [
            textLeadingConstraint,
            textTrailingConstraint,
            textView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            textWidthConstraint,
        ]
        comicConstraints = [
            comicPageImageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            comicPageImageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            comicPageImageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            comicPageImageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            comicPageImageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            comicPageImageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ]
        NSLayoutConstraint.activate(textConstraints)
        paginatedTextHeightConstraint = textView.heightAnchor.constraint(equalToConstant: 1)
        scrollingTextHeightConstraint = textView.heightAnchor.constraint(equalToConstant: 1)
        mount(.text)
    }

    func mount(_ source: Source) {
        switch source {
        case .text:
            mountText()
        case .comic:
            mountComic()
        case let .pdf(url):
            mountPDF(at: url)
        }
    }

    enum Source {
        case text
        case comic
        case pdf(URL)
    }

    func setTextMargins(_ margin: CGFloat) {
        textLeadingConstraint.constant = margin
        textTrailingConstraint.constant = -margin
        textWidthConstraint.constant = -2 * margin
    }

    private func mountText() {
        removePDFIfNeeded()
        NSLayoutConstraint.deactivate(comicConstraints)
        NSLayoutConstraint.activate(textConstraints)
        comicPageImageView.isHidden = true
        comicPageImageView.isUserInteractionEnabled = false
        textView.isHidden = false
        textView.isUserInteractionEnabled = true
        kind = .text
    }

    private func mountComic() {
        removePDFIfNeeded()
        NSLayoutConstraint.deactivate(textConstraints)
        NSLayoutConstraint.activate(comicConstraints)
        comicPageImageView.isHidden = false
        comicPageImageView.isUserInteractionEnabled = true
        textView.isHidden = true
        textView.isUserInteractionEnabled = false
        kind = .comic
    }

    private func mountPDF(at url: URL) {
        removePDFIfNeeded()
        pdfMountGeneration &+= 1
        let generation = pdfMountGeneration
        NSLayoutConstraint.deactivate(textConstraints + comicConstraints)
        textView.isHidden = true
        textView.isUserInteractionEnabled = false
        comicPageImageView.isHidden = true
        comicPageImageView.isUserInteractionEnabled = false
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        readerView.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: readerView.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: readerView.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: readerView.safeAreaLayoutGuide.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: readerView.bottomAnchor),
        ])
        let loadingIndicator = UIActivityIndicatorView(style: .large)
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.startAnimating()
        readerView.addSubview(loadingIndicator)
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: readerView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: readerView.centerYAnchor),
        ])
        self.pdfView = pdfView
        self.pdfLoadingIndicator = loadingIndicator
        kind = .pdf
        pdfPreparationTask = Task { [weak self, weak pdfView] in
            let normalized = await Task.detached(priority: .userInitiated) {
                PdfReadingPageNormalizer.normalizedDocument(from: url)
            }.value
            guard let self,
                  self.pdfMountGeneration == generation,
                  self.pdfView === pdfView
            else {
                return
            }
            pdfView?.document = normalized ?? PDFDocument(url: url)
            self.pdfLoadingIndicator?.stopAnimating()
            self.pdfLoadingIndicator?.removeFromSuperview()
            self.pdfLoadingIndicator = nil
        }
    }

    private func removePDFIfNeeded() {
        pdfPreparationTask?.cancel()
        pdfPreparationTask = nil
        pdfLoadingIndicator?.stopAnimating()
        pdfLoadingIndicator?.removeFromSuperview()
        pdfLoadingIndicator = nil
        pdfView?.removeFromSuperview()
        pdfView = nil
    }
}
#endif
