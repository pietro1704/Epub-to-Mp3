import Foundation

/// One observer per real Rust invocation; unavailable/disabled activities never fail conversion.
struct ConversionLiveActivitySession: Sendable {
    private let startAction: @Sendable (String, String) async -> Void
    private let progressAction: @Sendable (RustConversionCoordinator.ConversionProgressEvent) async -> Void
    private let chapterAction: @Sendable (RustConversionCoordinator.ChapterCompletionEvent) async -> Void
    private let phaseAction: @Sendable (ConversionActivityPhase, Int?, Int?) async -> Void

    init(jobID: String, isManualConversion: Bool) {
        #if !APP_FOUNDATION_HOST_TESTS && canImport(ActivityKit) && os(iOS)
        if #available(iOS 16.2, *), isManualConversion {
            let storage = ConversionActivityStorage(jobID: jobID)
            startAction = { await storage.start(title: $0, bookID: $1) }
            progressAction = { await storage.progress($0) }
            chapterAction = { await storage.chapter($0) }
            phaseAction = { await storage.setPhase($0, total: $1, completed: $2) }
            return
        }
        #endif
        startAction = { _, _ in }
        progressAction = { _ in }
        chapterAction = { _ in }
        phaseAction = { _, _, _ in }
    }

    func start(title: String, bookID: String) async { await startAction(title, bookID) }
    func progress(_ event: RustConversionCoordinator.ConversionProgressEvent) async { await progressAction(event) }
    func chapter(_ event: RustConversionCoordinator.ChapterCompletionEvent) async { await chapterAction(event) }
    func setPhase(_ phase: ConversionActivityPhase, total: Int? = nil, completed: Int? = nil) async {
        await phaseAction(phase, total, completed)
    }

    /// At process launch no conversion from the previous process is still running.
    static func dismissOrphans() {
        #if !APP_FOUNDATION_HOST_TESTS && canImport(ActivityKit) && os(iOS)
        if #available(iOS 16.2, *) { ConversionActivityStorage.dismissOrphans() }
        #endif
    }
}

#if !APP_FOUNDATION_HOST_TESTS && canImport(ActivityKit) && os(iOS)
import ActivityKit
import UIKit

@available(iOS 16.2, *)
private actor ConversionActivityStorage {
    private let jobID: String
    private var activity: Activity<ConversionActivityAttributes>?
    private var state = ConversionActivityProgress(chaptersDone: 0, chaptersTotal: 0, phase: .preparing)
    private var pending: Task<Void, Never>?
    private var lastPublication = Date.distantPast
    private var ended = false

    init(jobID: String) { self.jobID = jobID }

    func start(title: String, bookID: String) async {
        guard !Task.isCancelled, !ended, activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard await MainActor.run(body: { UIApplication.shared.applicationState == .active }) else { return }
        // Recheck after crossing actors so a cancellation cannot start an orphan.
        guard !ended else { return }
        do {
            activity = try Activity.request(
                attributes: ConversionActivityAttributes(bookTitle: title, bookId: bookID, jobID: jobID),
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(300)), pushType: nil)
        } catch { NSLog("[LiveActivity] Conversion activity could not start: %@", error.localizedDescription) }
    }

    func progress(_ event: RustConversionCoordinator.ConversionProgressEvent) {
        guard !ended, event.jobId == jobID else { return }
        let advanced = state.phase == .preparing || (state.chaptersTotal == 0 && event.chaptersTotal > 0)
        state.chaptersDone = max(state.chaptersDone, event.chaptersCompleted)
        state.chaptersTotal = max(state.chaptersTotal, event.chaptersTotal)
        if event.percent.isFinite { state.progressPercent = max(state.progressPercent ?? 0, min(99, max(0, event.percent))) }
        if state.phase != .cancelling { state.phase = .converting }
        publish(force: advanced)
    }

    func chapter(_ event: RustConversionCoordinator.ChapterCompletionEvent) {
        guard !ended, event.jobId == jobID else { return }
        let advanced = state.phase == .preparing
        state.chaptersDone = max(state.chaptersDone, event.chaptersCompleted)
        state.chaptersTotal = max(state.chaptersTotal, event.chaptersTotal)
        state.progressPercent = max(state.progressPercent ?? 0, min(99, event.progressPercent))
        state.currentChapterName = event.chapterTitle
        state.bookTitle = event.bookTitle
        if state.phase != .cancelling { state.phase = .converting }
        publish(force: advanced)
        if event.chaptersCompleted.isMultiple(of: 5) || event.chaptersCompleted == event.chaptersTotal {
            WidgetDataSync.updateConversionProgress(bookTitle: event.bookTitle,
                chaptersDone: event.chaptersCompleted, chaptersTotal: event.chaptersTotal,
                currentChapterName: event.chapterTitle)
        }
    }

    func setPhase(_ phase: ConversionActivityPhase, total: Int?, completed: Int?) async {
        guard !ended else { return }
        state.phase = phase
        if let total { state.chaptersTotal = max(state.chaptersTotal, total) }
        if let completed { state.chaptersDone = max(state.chaptersDone, completed) }
        guard phase.isTerminal else { publish(force: true); return }
        ended = true
        if phase == .completed { state.progressPercent = 100 }
        guard let activity else { return }
        let content = ActivityContent(state: state, staleDate: nil)
        let previous = pending
        let terminal = Task {
            await previous?.value
            await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(30)))
        }
        pending = terminal
        await terminal.value
        self.activity = nil
    }

    private func publish(force: Bool) {
        guard let activity, force || Date().timeIntervalSince(lastPublication) >= 2 else { return }
        lastPublication = Date()
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(300))
        let previous = pending
        pending = Task {
            await previous?.value
            await activity.update(content)
        }
    }

    static func dismissOrphans() {
        // Capture synchronously at launch; later jobs must never join this cleanup.
        let orphans = Activity<ConversionActivityAttributes>.activities
        Task {
            for activity in orphans {
                var state = activity.content.state
                if state.phase?.isTerminal != true { state.phase = .cancelled }
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
            }
        }
    }
}
#endif
