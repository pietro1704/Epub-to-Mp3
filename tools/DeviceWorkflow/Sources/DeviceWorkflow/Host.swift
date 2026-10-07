import Foundation
import Darwin

public enum HostInterruption {
    private static let lock = NSLock()
    private static var received = false
    private static var sources: [DispatchSourceSignal] = []
    public static var interrupted: Bool {
        lock.lock(); defer { lock.unlock() }
        return received
    }
    // Install only in the CLI. XCTest and library consumers retain their signal policy.
    public static func install() {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
            source.setEventHandler { lock.lock(); received = true; lock.unlock() }
            sources.append(source)
            source.resume()
        }
    }
}

public struct Command {
    public var arguments: [String]
    public var environment: [String: String] = [:]
    public var directory: URL
    public var log: URL
    public var timeout: TimeInterval
    public var phase: String
}

public struct CommandResult {
    public var code: Int32
    public var output: String
    public init(code: Int32 = 0, output: String = "") { self.code = code; self.output = output }
}

// The observer is called immediately after spawn and after reaping, even on timeout.
public typealias CommandRunner = (Command, (Int32?) throws -> Void) throws -> CommandResult

public enum HostProcess {
    public static func run(_ command: Command, observer: (Int32?) throws -> Void) throws -> CommandResult {
        guard !HostInterruption.interrupted else { throw WorkflowError("Workflow interrupted; inspect its persisted phase before restart.") }
        guard let executable = command.arguments.first else { throw WorkflowError("Empty command.") }
        let fd = open(command.log.path, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o600))
        guard fd >= 0 else { throw WorkflowError("Cannot open command log (errno=\(errno)).") }
        defer { close(fd) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else {
            throw WorkflowError("Cannot initialize subprocess attributes.")
        }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGINT)
        sigaddset(&defaults, SIGTERM)
        guard posix_spawn_file_actions_adddup2(&actions, fd, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, fd, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, command.directory.path) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF)) == 0 else {
            throw WorkflowError("Cannot isolate subprocess process group.")
        }
        let environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
        let args = command.arguments.map { strdup($0) } + [nil]
        let env = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { args.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        let error = args.withUnsafeBufferPointer { argv in
            env.withUnsafeBufferPointer { envp in
                posix_spawnp(&pid, executable, &actions, &attributes,
                             UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: envp.baseAddress!))
            }
        }
        guard error == 0, pid > 0 else { throw WorkflowError("Spawn failed (errno=\(error)): \(executable)") }
        var reaped = false
        func stopOwnedGroup() {
            guard !reaped else { return }
            kill(-pid, SIGTERM)
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            var status: Int32 = 0
            while ProcessInfo.processInfo.systemUptime < deadline {
                if waitpid(pid, &status, WNOHANG) == pid { reaped = true; break }
                usleep(20_000)
            }
            // Descendants can outlive the group leader; the group was created by this spawn.
            kill(-pid, SIGKILL)
            if !reaped { while waitpid(pid, &status, 0) < 0 && errno == EINTR {} }
            reaped = true
        }
        do {
            try observer(pid)
            let deadline = ProcessInfo.processInfo.systemUptime + command.timeout
            var status: Int32 = 0
            while true {
                if HostInterruption.interrupted { throw WorkflowError("\(command.phase) interrupted; inspect \(command.log.path).") }
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid { reaped = true; break }
                if result < 0 && errno != EINTR { throw WorkflowError("Cannot reap owned subprocess.") }
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    throw WorkflowError("\(command.phase) timed out; inspect \(command.log.path).")
                }
                usleep(20_000)
            }
            try observer(nil)
            let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            return CommandResult(code: code, output: try String(contentsOf: command.log, encoding: .utf8))
        } catch {
            stopOwnedGroup()
            try? observer(nil)
            throw error
        }
    }

    public static func identity(_ pid: Int32) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "lstart="]
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        } catch { return "" }
    }

    public static func resourceCheck() throws {
        var memory: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &memory, &size, nil, 0) == 0 else {
            throw WorkflowError("Cannot read native host resource capacity.")
        }
        #if arch(x86_64)
        if memory <= 8 * 1024 * 1024 * 1024 {
            var loads = [Double](repeating: 0, count: 3)
            guard getloadavg(&loads, 3) == 3 else { throw WorkflowError("Cannot read host load.") }
            guard loads[0] <= 6 else { throw WorkflowError("Host load exceeds 6; explicitly retry after the heavy job ends.") }
        }
        #endif
    }
}

public final class FileLease {
    private let descriptor: Int32
    public init(_ path: URL) throws {
        descriptor = open(path.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw WorkflowError("Cannot open lease: \(path.path)") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw WorkflowError("Another workflow/heavy job owns \(path.path); no actions started.")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

public enum DurableJSON {
    public static func read(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw WorkflowError("Expected a JSON object: \(url.path)")
        }
        return value
    }

    public static func write(_ value: [String: Any], to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw WorkflowError("Cannot create atomic checkpoint.") }
        defer { close(fd); try? FileManager.default.removeItem(at: temporary) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WorkflowError("Cannot write checkpoint.") }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else {
            throw WorkflowError("Cannot synchronize/replace checkpoint.")
        }
        let directory = open(parent.path, O_RDONLY | O_CLOEXEC)
        guard directory >= 0 else { throw WorkflowError("Cannot open checkpoint parent.") }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw WorkflowError("Cannot synchronize checkpoint parent.") }
    }

    public static func status(_ url: URL, identity: (Int32) -> String = HostProcess.identity) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ["status": "not_started", "nextAction": "Run an explicit preflight or benchmark."]
        }
        var state = try read(url)
        let pid = Evidence.integer(state["processPid"]).map { Int32($0) }
        let expected = state["processIdentity"] as? String ?? ""
        let live = pid.map { $0 > 0 && !expected.isEmpty && identity($0) == expected } ?? false
        state["processLive"] = live
        if live, let started = state["startedAtUnix"] as? Double {
            state["observedElapsedSeconds"] = max(0, Date().timeIntervalSince1970 - started)
        } else if ["preflight", "building", "testing", "preparing", "collecting", "cleanup"].contains(state["status"] as? String ?? "") {
            state["nextAction"] = "Recorded workflow ended; inspect its log/xcresult before any explicit restart."
        }
        return state
    }
}
