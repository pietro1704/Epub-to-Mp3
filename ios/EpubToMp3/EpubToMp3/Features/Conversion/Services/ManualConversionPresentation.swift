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
        var lines: [String] = []
        if session.isRunning, let progress = session.progress, progress.chaptersTotal > 0 {
            lines.append(L10n.string("convert.chapterProgress", progress.chaptersCompleted, progress.chaptersTotal))
        }
        if let voice = session.activeVoice, let engine = voice.engine,
           session.isRunning || session.phase == .completed {
            let name = SpeechModelPresentationStore.shared.displayName(
                engine: engine, modelID: voice.modelId, voice: voice.voice) ?? engine
            lines.append(L10n.string(engine == TtsSelection.systemEngine
                ? "convert.activeVoice.system" : "convert.activeVoice", name))
        }
        if session.skippedPages > 0, session.isRunning || session.phase == .completed {
            lines.append(session.skippedPages == 1 ? L10n.string("convert.pdfPagesSkipped.one")
                : L10n.string("convert.pdfPagesSkipped.many", session.skippedPages))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
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
