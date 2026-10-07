import Foundation
import Darwin
import DeviceWorkflow

func repositoryRoot() throws -> URL {
    if let path = ProcessInfo.processInfo.environment["MISE_PROJECT_ROOT"] { return URL(fileURLWithPath: path) }
    var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    while candidate.path != "/" {
        if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("scripts/ios_device_workflow.py").path) { return candidate }
        candidate.deleteLastPathComponent()
    }
    throw WorkflowError("Run from the repository or set MISE_PROJECT_ROOT.")
}

do {
    HostInterruption.install()
    let root = try repositoryRoot()
    let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()), root: root)
    let value = try Workflow(root: root, options: options).execute()
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} catch {
    FileHandle.standardError.write(Data("device-workflow: \(error)\n".utf8))
    exit(1)
}
