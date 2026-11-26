import Combine
import Foundation

@MainActor
final class ManualConversionSession: ObservableObject {
    enum Phase: Equatable {
        case idle, preparing, converting, cancelling, completed, cancelled, failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: RustConversionCoordinator.ConversionProgressEvent?
    @Published private(set) var result: RustConversionCoordinator.Result?
    @Published private(set) var errorMessage: String?
    /// PDF pages without selectable text, which the core leaves out of narration.
    @Published private(set) var skippedPages = 0
    private(set) var failure: Error?
    private(set) var requestID = UUID()

    private let executor: RustConversionCoordinator.Executor
    private var task: Task<RustConversionCoordinator.Result, Error>?
    private var activeJobID: String?

    init(executor: @escaping RustConversionCoordinator.Executor = RustConversionCoordinator.execute) {
        self.executor = executor
    }

    var isRunning: Bool {
        phase == .preparing || phase == .converting || phase == .cancelling
    }

    func reportValidationFailure(_ message: String) {
        guard !isRunning else { return }
        skippedPages = 0
        requestID = UUID()
        failure = nil
        result = nil
        progress = nil
        errorMessage = message
        phase = .failed
    }

    func run(file: URL, start: Int32, end: Int32, options: ConversionOptions?) async {
        guard !isRunning else { return }
        let jobID = UUID().uuidString
        activeJobID = jobID
        requestID = UUID()
        failure = nil
        result = nil
        progress = nil
        errorMessage = nil
        skippedPages = 0
        phase = .preparing
        let executor = self.executor
        let pending = Task { @MainActor [weak self] in
            try Task.checkCancellation()
            if file.pathExtension.lowercased() == "pdf" {
                let skipped = await Task.detached(priority: .userInitiated) { Self.skippedPageCount(in: file) }.value
                try Task.checkCancellation()
                if self?.activeJobID == jobID { self?.skippedPages = skipped }
            }
            let output = try await executor(file, jobID, start, end, options, { [weak self] event in
                self?.receive(event, jobID: jobID)
            }, nil)
            try Task.checkCancellation()
            return output
        }
        task = pending
        defer {
            if activeJobID == jobID {
                task = nil
                activeJobID = nil
            }
        }
        do {
            let output = try await withTaskCancellationHandler(operation: {
                try await pending.value
            }, onCancel: { pending.cancel() })
            guard activeJobID == jobID else { return }
            try Task.checkCancellation()
            guard !pending.isCancelled, phase != .cancelling else { throw CancellationError() }
            guard output.jobID == jobID else {
                throw EmbeddedConverterError.conversionFailed("Conversion returned a different manual job.")
            }
            result = output
            phase = .completed
        } catch {
            guard activeJobID == jobID else { return }
            if pending.isCancelled || error is CancellationError {
                phase = .cancelled
            } else {
                failure = error
                errorMessage = AppErrorReporter.message(error, context: "Manual conversion")
                phase = .failed
            }
        }
    }

    /// An unreadable book reports its own error through the conversion itself.
    private nonisolated static func skippedPageCount(in file: URL) -> Int {
        guard let data = try? ConverterFFIAdapter().openBook(at: file).metadataJSON,
              let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        return metadata["skipped_pages"] as? Int ?? 0
    }

    func cancel() {
        guard isRunning, phase != .cancelling else { return }
        phase = .cancelling
        task?.cancel()
    }

    private func receive(_ event: RustConversionCoordinator.ConversionProgressEvent, jobID: String) {
        guard activeJobID == jobID, event.jobId == jobID, isRunning,
              phase != .cancelling, task?.isCancelled != true else { return }
        progress = event
        phase = .converting
    }
}
