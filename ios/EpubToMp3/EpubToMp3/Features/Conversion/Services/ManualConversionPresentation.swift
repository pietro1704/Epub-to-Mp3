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

/// Wire states remain literal in storage and diagnostics; screens translate them.
enum ConversionStatusPresentation {
    static func label(_ state: String?) -> String {
        switch state?.lowercased() {
        case "completed", "done", "success": return L10n.string("convert.completed")
        case "running", "converting", "processing": return L10n.string("convert.converting")
        case "queued", "pending", "preparing", "started": return L10n.string("convert.preparing")
        case "cancelling", "canceling": return L10n.string("convert.cancelling")
        case "cancelled", "canceled": return L10n.string("convert.cancelled")
        case "failed", "error", "failure": return L10n.string("convert.failed")
        case "paused": return L10n.string("convert.paused")
        case "partial": return L10n.string("convert.partial")
        default: return L10n.string("convert.stateUnknown")
        }
    }
}
