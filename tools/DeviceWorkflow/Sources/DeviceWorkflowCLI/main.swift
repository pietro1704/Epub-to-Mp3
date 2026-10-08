import Foundation
import Darwin
import DeviceWorkflow

func repositoryRoot() throws -> URL {
    if let path = ProcessInfo.processInfo.environment["MISE_PROJECT_ROOT"] { return URL(fileURLWithPath: path) }
    var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    while candidate.path != "/" {
        if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("mise.toml").path),
           FileManager.default.fileExists(atPath: candidate.appendingPathComponent("tools/DeviceWorkflow/Package.swift").path) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }
    throw WorkflowError("Run from the repository or set MISE_PROJECT_ROOT.")
}

do {
    HostInterruption.install()
    let root = try repositoryRoot()
    let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()), root: root)
    let value = try Workflow(root: root, options: options, scopeObserver: { cases in
        let selected = cases.map { item in
            item.report.filter { ["sourcePath", "chapterStart", "chapterEnd", "chaptersRequested"].contains($0.key) }
        }
        if let data = try? JSONSerialization.data(withJSONObject: ["scope": selected], options: [.sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
        }
    }).execute()
    var output = value
    if !options.preview {
        let keys = ["status", "runID", "phase", "processPid", "processLive", "observedElapsedSeconds", "reportPath", "error", "nextAction"]
        output = value.filter { keys.contains($0.key) }
        if let timings = value["timings"] as? [String: Any] {
            let phases = ["totalSeconds", "preflightSeconds", "buildSeconds", "deviceWaitSeconds", "transferSeconds", "testWallSeconds", "collectionSeconds", "synthesisSeconds", "verificationSeconds"]
            output["timings"] = timings.filter { phases.contains($0.key) }
        }
        if let summary = value["testSummary"] as? [String: Any] {
            output["tests"] = summary.filter { ["passedTests", "failedTests", "skippedTests"].contains($0.key) }
        }
    }
    let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} catch {
    FileHandle.standardError.write(Data("device-workflow: \(error)\n".utf8))
    exit(1)
}
