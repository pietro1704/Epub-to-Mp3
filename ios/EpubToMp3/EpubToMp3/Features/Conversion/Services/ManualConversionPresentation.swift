import Foundation

enum ManualConversionPresentation {
    @MainActor
    static func title(for session: ManualConversionSession) -> String {
        switch session.phase {
        case .preparing:
            return L10n.string("convert.preparing")
        case .converting:
            guard let percent = session.progress?.percent, percent.isFinite else {
                return L10n.string("convert.converting")
            }
            return L10n.string("convert.progressPercent", Int(min(99, max(0, percent))))
        case .cancelling:
            return L10n.string("convert.cancelling")
        case .idle, .completed, .cancelled, .failed:
            return L10n.string("convert.startConversion")
        }
    }

    @MainActor
    static func detail(for session: ManualConversionSession) -> String? {
        if session.phase == .cancelled { return L10n.string("convert.cancelled") }
        guard session.isRunning, let progress = session.progress, progress.chaptersTotal > 0 else { return nil }
        return L10n.string("convert.chapterProgress", progress.chaptersCompleted, progress.chaptersTotal)
    }
}
