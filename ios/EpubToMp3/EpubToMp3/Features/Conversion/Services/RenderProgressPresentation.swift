import Foundation

struct RenderProgressPresentation: Decodable, Sendable {
    let fraction: Double
    let etaSeconds: Double?
    let freshCharsPerSecond: Double?
    let cachedSegments: Int

    var label: String? {
        guard fraction.isFinite, (0...1).contains(fraction) else { return nil }
        let percent = min(99, Int(fraction * 100))
        guard let etaSeconds, etaSeconds.isFinite, etaSeconds > 0,
              etaSeconds < Double(Int.max) else {
            return L10n.string("bookDetail.progressPercent", percent)
        }
        return L10n.string("bookProgress.estimate", percent, max(1, Int(ceil(etaSeconds / 60))))
    }
}
