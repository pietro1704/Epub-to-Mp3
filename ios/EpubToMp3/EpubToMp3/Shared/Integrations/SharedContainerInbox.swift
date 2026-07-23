import Foundation

/// Foundation-only App Group inbox bridge shared by the main app and the
/// Share Extension. Keep UI, LibraryStore, and SwiftUI out of this file so
/// the extension can compile it as an independent target.
enum SharedContainerInbox {
    static let appGroupID = "group.com.pietrocode.epubtomp3"
    static let inboxSubpath = "Inbox"

    static func inboxURL(
        fileManager: FileManager = .default,
        groupID: String = appGroupID
    ) -> URL? {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        ) else {
            return nil
        }
        let inbox = container.appendingPathComponent(inboxSubpath, isDirectory: true)
        if !fileManager.fileExists(atPath: inbox.path) {
            try? fileManager.createDirectory(
                at: inbox,
                withIntermediateDirectories: true
            )
        }
        return inbox
    }

    @discardableResult
    static func dropIntoInbox(
        source: URL,
        fileManager: FileManager = .default,
        groupID: String = appGroupID
    ) throws -> URL {
        guard let inbox = inboxURL(
            fileManager: fileManager,
            groupID: groupID
        ) else {
            throw NSError(
                domain: "SharedContainerInbox",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "App Group container not available for \(groupID). Check entitlements + provisioning."]
            )
        }
        let destination = uniqueDestination(
            for: source.lastPathComponent,
            in: inbox,
            fileManager: fileManager
        )
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }

    private static func uniqueDestination(
        for filename: String,
        in directory: URL,
        fileManager: FileManager
    ) -> URL {
        let candidate = directory.appendingPathComponent(filename)
        if !fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }
        let nsName = filename as NSString
        let base = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        for n in 1...999 {
            let next = directory.appendingPathComponent(
                ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            )
            if !fileManager.fileExists(atPath: next.path) {
                return next
            }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(filename)")
    }
}
