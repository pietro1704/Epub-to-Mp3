import Foundation
#if canImport(Vision)
import PDFKit
import Vision
#endif

/// Reads the image-only pages of a PDF with the platform OCR and hands the text to the Rust
/// core, which keeps it beside the book and reads it on every open. Pages already stored are
/// not read again; a page that fails or reads blank is skipped so the rest still opens.
struct PdfOcrPreparer: Sendable {
    let listPages: @Sendable (URL) throws -> [Int]
    let recognize: @Sendable (URL, Int) throws -> String
    let store: @Sendable (URL, Int, String) throws -> Void

    /// Returns how many pages were newly read. Only cancellation is an error: the open
    /// that follows reports an unreadable or still textless PDF itself.
    @discardableResult
    func prepare(_ url: URL, isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> Int {
        guard url.pathExtension.lowercased() == "pdf" else { return 0 }
        let work = Task.detached(priority: .userInitiated) { () throws -> Int in
            guard let pages = try? listPages(url) else { return 0 }
            let stored = Self.storedPages(url)
            var read = 0
            for page in pages where !stored.contains(page) {
                try Task.checkCancellation()
                guard !isCancelled() else { throw CancellationError() }
                if readPage(page, of: url) { read += 1 }
            }
            return read
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private func readPage(_ page: Int, of url: URL) -> Bool {
        guard let text = try? recognize(url, page).trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return false }
        return (try? store(url, page, text)) != nil
    }

    private static func storedPages(_ url: URL) -> Set<Int> {
        struct Sidecar: Decodable { let pages: [String: String] }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: url.path + ".ocr.json")),
              let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data) else { return [] }
        return Set(sidecar.pages.keys.compactMap(Int.init))
    }
}

#if canImport(Vision)
extension PdfOcrPreparer {
    static func vision(adapter: ConverterFFIAdapter = ConverterFFIAdapter()) -> PdfOcrPreparer {
        PdfOcrPreparer(
            listPages: { try adapter.pdfImagePages(at: $0) },
            recognize: { url, page in
                // A mixed book tells its language; a pure scan has no text to tell it from.
                let bookLanguage = (try? adapter.bookLanguage(at: url))?.resolvedLanguage(userCorrection: nil)
                return try autoreleasepool {
                    try VisionPageReader.text(of: url, page: page, bookLanguage: bookLanguage)
                }
            },
            store: { try adapter.setPdfOcrText($2, page: $1, at: $0) }
        )
    }
}

/// Renders one PDF page and reads it with the on-device Vision recognizer (blocking).
enum VisionPageReader {
    private static let targetWidth: CGFloat = 1600

    static func text(of url: URL, page number: Int, bookLanguage: String?) throws -> String {
        guard let page = PDFDocument(url: url)?.page(at: number - 1), let image = render(page) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = try request.supportedRecognitionLanguages()
        let languages = recognitionLanguages(bookLanguage: bookLanguage, supported: supported)
        if !languages.isEmpty { request.recognitionLanguages = languages }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// The book language first, then pt-BR, limited to what this system's recognizer reads.
    static func recognitionLanguages(bookLanguage: String?, supported: [String]) -> [String] {
        func primary(_ tag: String) -> String { tag.split(separator: "-").first.map { $0.lowercased() } ?? "" }
        var result: [String] = []
        for language in [bookLanguage, "pt-BR", "en-US"].compactMap({ $0 }) {
            let match = supported.first { $0.caseInsensitiveCompare(language) == .orderedSame }
                ?? supported.first { primary($0) == primary(language) }
            if let match, !result.contains(match) { result.append(match) }
        }
        return result
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        let sideways = page.rotation % 180 != 0
        let size = sideways ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = targetWidth / size.width
        // A very tall page must not allocate an unbounded bitmap.
        let height = min(max(size.height * scale, 1), targetWidth * 4)
        guard let context = CGContext(
            data: nil, width: Int(targetWidth), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }
}
#endif
