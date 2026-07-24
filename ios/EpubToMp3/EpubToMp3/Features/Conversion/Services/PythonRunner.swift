// PythonRunner.swift
//
// Single-threaded executor for every PythonKit call in the app.
//
// PythonKit does NOT manage the CPython GIL — its README is explicit:
// "PythonKit is not thread-safe." A `DispatchQueue`, even a serial one,
// hops worker threads between blocks (the global thread pool decides
// which kernel thread runs each block). That hop is the root cause of
// the `_PyObject_Malloc` / `unicode_decode_utf8` bad-access crashes
// observed when an `import` ran on a thread different from the one
// that called `Py_Initialize`: CPython's internal allocator caches
// per-thread state and reaches into it without re-acquiring the GIL,
// so a new thread reads garbage.
//
// `PythonRunner` owns a single `Thread` and a hand-rolled FIFO queue
// guarded by an `NSCondition`. Every Python call funnels through
// `async(_:)` — the block ALWAYS runs on this thread, so PyObject
// allocation, the GIL, and module-import state stay on one kernel
// thread for the lifetime of the process.
//
// API surface mirrors `DispatchQueue.async` so call sites need no
// behavioural rewrite. Keep this file the *only* path into PythonKit;
// regressions creep back in when someone re-introduces a stray
// `DispatchQueue.async { Python.import(...) }`.

import Foundation

final class PythonRunner: @unchecked Sendable {
    static let shared = PythonRunner()

    private let condition = NSCondition()
    private var pending: [() -> Void] = []
    private var running = true
    private let thread: Thread

    private init() {
        let bootstrap = Bootstrap()
        let t = Thread { [weak bootstrap] in
            bootstrap?.runLoop()
        }
        t.name = "epub2mp3.python-runner"
        t.qualityOfService = .userInitiated
        self.thread = t
        // Bootstrap holds a strong ref back to the runner so the
        // loop drains `self.pending`; the runner keeps the bootstrap
        // alive via `t`'s closure capture.
        bootstrap.owner = self
        t.start()
    }

    /// Schedule `block` to run on the dedicated Python thread.
    /// Non-blocking; ordering with previous `async` calls is FIFO.
    func async(_ block: @escaping () -> Void) {
        condition.lock()
        pending.append(block)
        condition.signal()
        condition.unlock()
    }

    /// Convenience that mirrors `DispatchSemaphore`-based sync bridging.
    /// Blocks the caller until `block` returns on the Python thread.
    /// Do NOT call from the Python thread itself — that would deadlock.
    func sync<T>(_ block: @escaping () throws -> T) throws -> T {
        precondition(
            Thread.current !== thread,
            "PythonRunner.sync called from the Python thread itself — deadlock"
        )
        var outcome: Result<T, Error>!
        let done = DispatchSemaphore(value: 0)
        async {
            outcome = Result { try block() }
            done.signal()
        }
        done.wait()
        return try outcome.get()
    }

    // MARK: - Swift Concurrency bridge

    /// Await `block` on the dedicated Python thread. Replaces the
    /// manual `withCheckedThrowingContinuation { cont in self.async { … } }`
    /// boilerplate at every call site.
    func callAsync<T: Sendable>(_ block: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            self.async {
                do {
                    cont.resume(returning: try block())
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// ``callAsync`` with a wall-clock deadline. When `timeout` elapses
    /// before the block returns, the continuation resumes with
    /// ``TimeoutError`` and the block's result is silently discarded.
    ///
    /// This solves the ``withTimeout`` + ``withCheckedThrowingContinuation``
    /// deadlock: ``withThrowingTaskGroup`` can never exit when its
    /// continuation-based child hasn't resumed yet. Here, the one-resume
    /// gate guarantees exactly one side wins.
    func callAsync<T: Sendable>(timeout seconds: TimeInterval, label: String = "PythonRunner", _ block: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            let completionGate = CompletionGate()

            self.async {
                let result: Result<T, Error>
                do {
                    result = .success(try block())
                } catch {
                    result = .failure(error)
                }
                completionGate.lock.lock()
                guard !completionGate.resumed else {
                    completionGate.lock.unlock()
                    return
                }
                completionGate.resumed = true
                completionGate.lock.unlock()
                cont.resume(with: result)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                completionGate.lock.lock()
                guard !completionGate.resumed else {
                    completionGate.lock.unlock()
                    return
                }
                completionGate.resumed = true
                completionGate.lock.unlock()
                cont.resume(throwing: TimeoutError(seconds: seconds, label: label))
            }
        }
    }

    fileprivate func drainNext() -> (() -> Void)? {
        condition.lock()
        defer { condition.unlock() }
        while pending.isEmpty && running {
            condition.wait()
        }
        guard running else { return nil }
        return pending.removeFirst()
    }

    fileprivate var isRunning: Bool {
        condition.lock()
        defer { condition.unlock() }
        return running
    }
}

private final class CompletionGate: @unchecked Sendable {
    let lock = NSLock()
    var resumed = false
}

private final class Bootstrap: @unchecked Sendable {
    weak var owner: PythonRunner?

    func runLoop() {
        // Each iteration pops the next block under the condition and
        // runs it on this kernel thread. The `while owner != nil` guard
        // lets the process terminate cleanly if the singleton is ever
        // torn down — in practice it lives for the app's lifetime.
        while let runner = owner, runner.isRunning {
            guard let next = runner.drainNext() else { return }
            next()
        }
    }
}
