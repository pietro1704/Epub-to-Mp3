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
    private var pdfView: PDFView?

    private(set) var kind: Kind = .text

    var isDisplayingText: Bool { kind == .text }
    var isDisplayingComic: Bool { kind == .comic }

    init(textView: UITextView, comicPageImageView: UIImageView) {
        self.textView = textView
        self.comicPageImageView = comicPageImageView
    }

    func mountText(
        textConstraints: [NSLayoutConstraint],
        comicConstraints: [NSLayoutConstraint]
    ) {
        removePDFIfNeeded()
        NSLayoutConstraint.deactivate(comicConstraints)
        NSLayoutConstraint.activate(textConstraints)
        comicPageImageView.isHidden = true
        textView.isHidden = false
        textView.isUserInteractionEnabled = true
        kind = .text
    }

    func mountComic(
        textConstraints: [NSLayoutConstraint],
        comicConstraints: [NSLayoutConstraint]
    ) {
        removePDFIfNeeded()
        NSLayoutConstraint.deactivate(textConstraints)
        NSLayoutConstraint.activate(comicConstraints)
        comicPageImageView.isHidden = false
        textView.isHidden = true
        comicPageImageView.isUserInteractionEnabled = true
        kind = .comic
    }

    func mountPDF(at url: URL, in container: UIView) {
        removePDFIfNeeded()
        textView.isHidden = true
        textView.isUserInteractionEnabled = false
        comicPageImageView.isHidden = true
        comicPageImageView.isUserInteractionEnabled = false
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.document = PDFDocument(url: url)
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.pdfView = pdfView
        kind = .pdf
    }

    private func removePDFIfNeeded() {
        pdfView?.removeFromSuperview()
        pdfView = nil
    }
}
#endif
