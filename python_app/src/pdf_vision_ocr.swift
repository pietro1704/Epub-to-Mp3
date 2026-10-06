import AppKit
import Foundation
import ImageIO
import PDFKit
import Vision

private struct OCRLine {
    let text: String
    let confidence: Float
    let bounds: CGRect
}

private struct OCRRecord: Codable {
    let sourcePageIndex: Int
    let partIndex: Int
    let text: String

    enum CodingKeys: String, CodingKey {
        case sourcePageIndex = "source_page_index"
        case partIndex = "part_index"
        case text
    }
}

private let recognitionLanguages = ["pt-PT", "en-US"]
private let splitBoundary: CGFloat = 0.48
private let oppositeSplitBoundary: CGFloat = 0.52

private func render(_ page: PDFPage) throws -> CGImage {
    let bounds = page.bounds(for: .mediaBox)
    guard bounds.width > 0, bounds.height > 0 else {
        throw NSError(domain: "VisionPDFOCR", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "PDF page has no drawable bounds",
        ])
    }
    let scale: CGFloat = 1
    let image = NSImage(size: NSSize(width: bounds.width * scale, height: bounds.height * scale))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        throw NSError(domain: "VisionPDFOCR", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Unable to create a PDF drawing context",
        ])
    }
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(origin: .zero, size: image.size))
    context.interpolationQuality = .high
    context.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: context)
    image.unlockFocus()
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw NSError(domain: "VisionPDFOCR", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Unable to rasterize PDF page",
        ])
    }
    return cgImage
}

private func recognize(_ image: CGImage, orientation: CGImagePropertyOrientation) throws -> [OCRLine] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = recognitionLanguages
    request.usesLanguageCorrection = true
    try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
    return (request.results ?? []).compactMap { observation in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        return OCRLine(
            text: candidate.string.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: candidate.confidence,
            bounds: observation.boundingBox
        )
    }.filter { !$0.text.isEmpty }
}

private func recognitionScore(_ lines: [OCRLine]) -> Double {
    lines.reduce(0) { partial, line in
        partial + Double(line.confidence) * Double(min(line.text.count, 160))
    }
}

private func isTwoUpSpread(_ lines: [OCRLine]) -> Bool {
    let left = lines.filter { $0.bounds.maxX < splitBoundary }
    let right = lines.filter { $0.bounds.minX > oppositeSplitBoundary }
    let middleCount = lines.count - left.count - right.count
    // Running heads and centered canto labels may overlap the gutter even
    // though the body text is a two-page spread. Keep those sparse lines from
    // collapsing the two logical pages back into one.
    let splitThreshold = max(4, max(left.count, right.count) / 3)
    return left.count >= 6 && right.count >= 6 && middleCount <= splitThreshold
}

private func orientationScore(_ lines: [OCRLine]) -> Double {
    let spreadBonus = isTwoUpSpread(lines) ? 1_000_000 : 0
    return recognitionScore(lines) + Double(spreadBonus)
}

private func sampleIndexes(from pages: [Int]) -> [Int] {
    guard !pages.isEmpty else { return [] }
    let positions = [0, pages.count / 3, (pages.count * 2) / 3, pages.count - 1]
    return Array(Set(positions.map { pages[$0] })).sorted()
}

private func preferredOrientation(document: PDFDocument, pages: [Int]) throws -> CGImagePropertyOrientation {
    let sampleImages = try sampleIndexes(from: pages).compactMap { index -> CGImage? in
        guard let page = document.page(at: index - 1) else { return nil }
        return try render(page)
    }
    var image: CGImage?
    var highestCharacterCount = -1
    for sample in sampleImages {
        let characterCount = try recognize(sample, orientation: .up)
            .map(\.text.count)
            .reduce(0, +)
        if characterCount > highestCharacterCount {
            highestCharacterCount = characterCount
            image = sample
        }
    }
    guard let image else {
        return .up
    }
    let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
    return try orientations.max { left, right in
        try orientationScore(recognize(image, orientation: left))
            < orientationScore(recognize(image, orientation: right))
    } ?? .up
}

private func orderedText(_ lines: [OCRLine]) -> String {
    lines.sorted {
        if abs($0.bounds.midY - $1.bounds.midY) < 0.008 {
            return $0.bounds.minX < $1.bounds.minX
        }
        return $0.bounds.midY > $1.bounds.midY
    }.map(\.text).joined(separator: "\n")
}

private func logicalPages(from lines: [OCRLine]) -> [String] {
    if isTwoUpSpread(lines) {
        // Keep running heads and any line that reaches the gutter. The strict
        // bounds above only decide whether this is a spread; midpoint grouping
        // retains every recognized line in one of its logical pages.
        let left = lines.filter { $0.bounds.midX <= 0.5 }
        let right = lines.filter { $0.bounds.midX > 0.5 }
        return [orderedText(left), orderedText(right)].filter { !$0.isEmpty }
    }
    let text = orderedText(lines)
    return text.isEmpty ? [] : [text]
}

private func run() throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    var requestedOrientation: CGImagePropertyOrientation?
    var detectOrientationOnly = false
    while let option = arguments.first, option.hasPrefix("--") {
        arguments.removeFirst()
        if option == "--detect-orientation" {
            detectOrientationOnly = true
            continue
        }
        let prefix = "--orientation="
        guard option.hasPrefix(prefix),
              let rawValue = UInt32(option.dropFirst(prefix.count)),
              let orientation = CGImagePropertyOrientation(rawValue: rawValue) else {
            throw NSError(domain: "VisionPDFOCR", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported OCR option: \(option)",
            ])
        }
        requestedOrientation = orientation
    }
    guard let path = arguments.first, arguments.count > 1 else {
        throw NSError(domain: "VisionPDFOCR", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "Usage: pdf_vision_ocr <pdf-path> <page-number>...",
        ])
    }
    let requestedPages = arguments.dropFirst().compactMap(Int.init).filter { $0 > 0 }
    guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
        throw NSError(domain: "VisionPDFOCR", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "Unable to open PDF document",
        ])
    }
    let orientation = try requestedOrientation ?? preferredOrientation(document: document, pages: requestedPages)
    if detectOrientationOnly {
        print(orientation.rawValue)
        return
    }
    let encoder = JSONEncoder()
    for sourcePageIndex in requestedPages {
        guard let page = document.page(at: sourcePageIndex - 1) else { continue }
        do {
            let textPages = try logicalPages(from: recognize(try render(page), orientation: orientation))
            for (offset, text) in textPages.enumerated() {
                let record = OCRRecord(
                    sourcePageIndex: sourcePageIndex,
                    partIndex: offset + 1,
                    text: text
                )
                let data = try encoder.encode(record)
                print(String(decoding: data, as: UTF8.self))
            }
        } catch {
            fputs("OCR failed for PDF page \(sourcePageIndex): \(error.localizedDescription)\n", stderr)
        }
    }
}

do {
    try run()
} catch {
    fputs("Vision PDF OCR failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
