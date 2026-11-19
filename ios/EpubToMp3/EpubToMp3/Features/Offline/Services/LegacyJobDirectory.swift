import Foundation
import os

/// The only way a legacy job id becomes a filesystem location.
///
/// Legacy retained audio and reader text live in `Audiobooks/<jobId>`. The id
/// comes from a server snapshot or a persisted library entity, so it is not
/// trusted: an empty id, `.`, `..`, a separator or an embedded NUL (Foundation
/// truncates the path at NUL) would otherwise address the Audiobooks root, a
/// parent or another book, and a removal would delete every book's audio.
/// A job folder that is itself a symlink is also refused, because operations
/// inside it would follow the link outside the root.
enum LegacyJobDirectory {
    enum Rejection: String, Error, Equatable {
        /// The id is not a single, bounded, printable path component.
        case invalidComponent
        /// The id resolved to something other than a direct child of the root.
        case outsideRoot
        /// The job folder exists as a symbolic link.
        case symbolicLink
    }

    /// NAME_MAX on Apple file systems, in UTF-8 bytes.
    static let maximumComponentBytes = 255

    private static let log = Logger(subsystem: "epub2mp3", category: "Storage")

    /// True when `value` can only ever name one direct child of a directory.
    static func isSafeComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != "..",
              value.utf8.count <= maximumComponentBytes,
              !value.contains("/"), !value.contains("\\") else { return false }
        return !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Resolve `jobID` to its folder directly under `root` without creating
    /// anything. The root's own symlinks are resolved first, so the comparison
    /// is between canonical paths and an alias of the root is still accepted.
    static func resolve(_ jobID: String, under root: URL) -> Result<URL, Rejection> {
        guard isSafeComponent(jobID) else { return .failure(.invalidComponent) }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let directory = canonicalRoot.appendingPathComponent(jobID, isDirectory: true).standardizedFileURL
        guard directory.deletingLastPathComponent().standardizedFileURL.path == canonicalRoot.path else {
            return .failure(.outsideRoot)
        }
        if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return .failure(.symbolicLink)
        }
        return .success(directory)
    }

    /// `resolve` for callers that treat a rejected id as "nothing stored".
    /// The rejection type is logged; the id and paths are never logged.
    static func directory(for jobID: String, under root: URL, operation: String) -> URL? {
        switch resolve(jobID, under: root) {
        case .success(let directory):
            return directory
        case .failure(let rejection):
            log.error("Refused legacy job folder for \(operation, privacy: .public): \(rejection.rawValue, privacy: .public)")
            return nil
        }
    }
}
