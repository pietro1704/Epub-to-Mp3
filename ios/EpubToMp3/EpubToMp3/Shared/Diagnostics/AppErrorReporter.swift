import Foundation

/// Keeps user-visible failures observable in LLDB and attached device consoles.
enum AppErrorReporter {
    @discardableResult
    static func message(_ error: Error, context: String,
                        destination: FileHandle = .standardError) -> String {
        let failure = error as NSError
        let message = error.localizedDescription
        write(message, context: "\(context) [\(failure.domain):\(failure.code)]", destination: destination)
        return message
    }

    @discardableResult
    static func message(_ message: String, context: String,
                        destination: FileHandle = .standardError) -> String {
        write(message, context: context, destination: destination)
        return message
    }

    private static func write(_ message: String, context: String, destination: FileHandle) {
        let diagnostic = message.components(separatedBy: .newlines)
            .map { "[App][Error] \(context): \($0)" }.joined(separator: "\n") + "\n"
        destination.write(Data(diagnostic.utf8))
    }
}
