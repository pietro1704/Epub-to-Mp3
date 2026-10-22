import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

enum PdfSpreadDetection {
    struct RecognizedLine {
        let bounds: CGRect
        let characterCount: Int
        let confidence: Float
    }

    private static let splitBoundary: CGFloat = 0.48
    private static let oppositeSplitBoundary: CGFloat = 0.52
    static func isTwoUpSpread(_ lines: [RecognizedLine]) -> Bool {
        let left = lines.filter { $0.bounds.maxX < splitBoundary }
        let right = lines.filter { $0.bounds.minX > oppositeSplitBoundary }
        let middleCount = lines.count - left.count - right.count
        let splitThreshold = max(4, max(left.count, right.count) / 3)
        return left.count >= 6 && right.count >= 6 && middleCount <= splitThreshold
    }

    static func spreadOrientation(in document: PDFDocument) -> CGImagePropertyOrientation? {
        let positions = [0, document.pageCount / 3, (document.pageCount * 2) / 3, document.pageCount - 1]
        let sampleIndexes = Array(Set(positions)).sorted()
        let orientations: [CGImagePropertyOrientation] = [.right, .left]
        var spreadCounts: [UInt32: Int] = [:]
        var scores: [UInt32: Double] = [:]

        for index in sampleIndexes {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.height > bounds.width, let image = PdfReadingPageNormalizer.render(page) else { continue }
            for orientation in orientations {
                guard let lines = recognize(image, orientation: orientation) else { continue }
                let rawValue = orientation.rawValue
                scores[rawValue, default: 0] += recognitionScore(lines)
                if isTwoUpSpread(lines) {
                    spreadCounts[rawValue, default: 0] += 1
                }
            }
        }

        return orientations
            .filter { (spreadCounts[$0.rawValue] ?? 0) > 0 }
            .max { left, right in
                (scores[left.rawValue] ?? 0) < (scores[right.rawValue] ?? 0)
            }
    }

    static func hasNoSelectableText(in document: PDFDocument) -> Bool {
        let positions = [0, document.pageCount / 2, document.pageCount - 1]
        for index in Set(positions) {
            let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let text, !text.isEmpty {
                return false
            }
        }
        return true
    }

    private static func recognize(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation
    ) -> [RecognizedLine]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.recognitionLanguages = ["pt-PT", "en-US"]
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
        } catch {
            return nil
        }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            return RecognizedLine(
                bounds: observation.boundingBox,
                characterCount: candidate.string.count,
                confidence: candidate.confidence
            )
        }
    }

    private static func recognitionScore(_ lines: [RecognizedLine]) -> Double {
        lines.reduce(0) { partial, line in
            partial + Double(line.confidence) * Double(min(line.characterCount, 160))
        }
    }

}
