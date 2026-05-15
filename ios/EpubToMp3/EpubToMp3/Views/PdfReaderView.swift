import SwiftUI
import PDFKit

struct PdfReaderView: View {
    let document: PDFDocument
    @Binding var currentPageIndex: Int

    init(document: PDFDocument, currentPageIndex: Binding<Int> = .constant(0)) {
        self.document = document
        self._currentPageIndex = currentPageIndex
    }

    var body: some View {
        #if os(iOS)
        _PdfReaderViewIOS(document: document, currentPageIndex: $currentPageIndex)
        #else
        _PdfReaderViewMac(document: document, currentPageIndex: $currentPageIndex)
        #endif
    }
}

// MARK: - iOS / iPadOS

#if os(iOS)
import UIKit

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
            if idx != parent.currentPageIndex {
                DispatchQueue.main.async {
                    self.parent.currentPageIndex = idx
                }
            }
        }
    }
}
#endif

// MARK: - macOS

#if os(macOS)
import AppKit

private struct _PdfReaderViewMac: NSViewRepresentable {
    let document: PDFDocument
    @Binding var currentPageIndex: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.delegate = context.coordinator
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

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
        }
        guard let currentPage = view.currentPage else { return }
        let viewIndex = document.index(for: currentPage)
        if viewIndex != currentPageIndex,
           let target = document.page(at: max(0, min(currentPageIndex, document.pageCount - 1))) {
            view.go(to: target)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, PDFViewDelegate {
        var parent: _PdfReaderViewMac
        init(parent: _PdfReaderViewMac) { self.parent = parent }

        @objc func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView,
                  let page = view.currentPage else { return }
            let idx = parent.document.index(for: page)
            if idx != parent.currentPageIndex {
                DispatchQueue.main.async {
                    self.parent.currentPageIndex = idx
                }
            }
        }
    }
}
#endif
