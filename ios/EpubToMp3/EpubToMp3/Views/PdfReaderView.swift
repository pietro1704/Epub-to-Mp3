import SwiftUI
import PDFKit

import UIKit

/// HIG-aligned PDF surface. Apple Books renders PDFs natively via
/// `PDFView` so the layout, images, and selectable text round-trip
/// untouched. We mirror that pattern here instead of extracting plain
/// text into the reflow reader — PDFs are layout-anchored content.
///
/// On iOS / iPadOS this wraps a `UIViewRepresentable`; on macOS the
/// same `PDFView` class is wrapped via `NSViewRepresentable`. The
/// behaviour (auto-scale, horizontal page-by-page navigation,
/// usePageViewController on iOS) is identical across both.
struct PdfReaderView: View {
    let document: PDFDocument
    /// Optional binding so `BookOpenView` / future resume integration
    /// can read or set the current page without owning the PDFView.
    @Binding var currentPageIndex: Int

    init(document: PDFDocument, currentPageIndex: Binding<Int> = .constant(0)) {
        self.document = document
        self._currentPageIndex = currentPageIndex
    }

    var body: some View {
        _PdfReaderViewIOS(document: document, currentPageIndex: $currentPageIndex)
    }
}

// MARK: - iOS / iPadOS

private struct _PdfReaderViewIOS: UIViewRepresentable {
    let document: PDFDocument
    @Binding var currentPageIndex: Int

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.usePageViewController(true)
        view.backgroundColor = .systemBackground
        view.delegate = context.coordinator
        // Seek to the initial page binding once the view has a document.
        if let page = document.page(at: max(0, min(currentPageIndex, document.pageCount - 1))) {
            view.go(to: page)
        }
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view
        )
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
        }
        // Only programmatically navigate when the binding diverges
        // from PDFView's notion of the current page; otherwise we'd
        // fight the user's swipe gestures.
        guard let currentPage = view.currentPage else { return }
        let viewIndex = document.index(for: currentPage)
        if viewIndex != currentPageIndex,
           let target = document.page(at: max(0, min(currentPageIndex, document.pageCount - 1))) {
            view.go(to: target)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, PDFViewDelegate {
        var parent: _PdfReaderViewIOS
        init(parent: _PdfReaderViewIOS) { self.parent = parent }

        @objc func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView,
                  let page = view.currentPage else { return }
            let idx = parent.document.index(for: page)
            // Avoid feedback loops — only write through when the value
            // actually changes.
            if idx != parent.currentPageIndex {
                DispatchQueue.main.async {
                    self.parent.currentPageIndex = idx
                }
            }
        }
    }
}
