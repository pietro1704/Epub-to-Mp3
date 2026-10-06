import Foundation

/// Bridge between the Share Extension and the main app.
///
/// When the user invokes the system Share Sheet from Apple Books,
/// Files, Safari or any host app and picks `EpubToMp3` as the
/// destination, the Share Extension copies the shared EPUB/PDF into
/// the App Group container so the main app can pick it up on next
/// foreground. The extension cannot launch the parent app on iOS, so
/// this drop-folder + on-appear scan is the supported flow.
///
/// Apple Books **purchased** content is FairPlay-DRM protected and
/// the Share Sheet does **not** expose the underlying file — that is
/// an Apple limitation, not something this importer can work around.
/// Non-DRM EPUBs/PDFs the user imported into Books (or any other
/// app) come through correctly.
///
/// Group ID must match both:
///   - main app entitlement `com.apple.security.application-groups`
///   - extension entitlement `com.apple.security.application-groups`
enum SharedContainerImporter {

    /// App Group identifier. Keep in sync with the entitlement files
    /// on both the main app and the Share Extension targets.
    static let appGroupID = SharedContainerInbox.appGroupID

    // Guarded by an internal NSLock so the global dedup cache is
    // concurrency-safe under Swift 6. The cache key is fixed
    // (`appGroupID`) and `FileManager.containerURL` is documented as
    // thread-safe; this lock only protects the cache assignment.
    private final class AvailabilityState: @unchecked Sendable {
        let lock = NSLock()
        var cache: [String: Bool] = [:]
    }

    private static let availabilityState = AvailabilityState()

    static var isAppGroupAvailable: Bool {
        availabilityState.lock.lock()
        if let cached = availabilityState.cache[appGroupID] {
            availabilityState.lock.unlock()
            return cached
        }
        availabilityState.lock.unlock()
        let available = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) != nil
        availabilityState.lock.lock()
        availabilityState.cache[appGroupID] = available
        availabilityState.lock.unlock()
        return available
    }

    /// Subdirectory inside the group container where the extension
    /// drops incoming EPUB/PDF files. `Inbox/` mirrors the convention
    /// Apple uses for system-provided document drop folders.
    static let inboxSubpath = SharedContainerInbox.inboxSubpath

    /// Result of importing a single shared file.
    struct ImportOutcome: Equatable {
        let url: URL
        let importedBookID: String?
        let error: String?
    }

    /// Returns the URL of the shared Inbox folder, creating it if
    /// missing. Returns `nil` when the App Group container is not
    /// available (extension target not provisioned or running in a
    /// host that doesn't see the group — common on simulators
    /// without proper provisioning).
    static func inboxURL(
        fileManager: FileManager = .default,
        groupID: String = appGroupID,
        containerURLProvider: ((FileManager, String) -> URL?)? = nil
    ) -> URL? {
        availabilityState.lock.lock()
        let cached = availabilityState.cache[groupID]
        availabilityState.lock.unlock()
        if let cached, !cached {
            return nil
        }
        let resolveContainer = containerURLProvider ?? {
            $0.containerURL(forSecurityApplicationGroupIdentifier: $1)
        }
        guard let container = resolveContainer(fileManager, groupID) else {
            availabilityState.lock.lock()
            availabilityState.cache[groupID] = false
            availabilityState.lock.unlock()
            return nil
        }
        availabilityState.lock.lock()
        availabilityState.cache[groupID] = true
        availabilityState.lock.unlock()
        let inbox = container.appendingPathComponent(inboxSubpath, isDirectory: true)
        if !fileManager.fileExists(atPath: inbox.path) {
            try? fileManager.createDirectory(
                at: inbox,
                withIntermediateDirectories: true
            )
        }
        return inbox
    }

    /// Enumerate every EPUB / PDF currently sitting in the Inbox.
    /// The main app calls this on launch / `scenePhase == .active` to
    /// drain anything the extension has dropped.
    static func pendingFiles(
        fileManager: FileManager = .default,
        groupID: String = appGroupID
    ) -> [URL] {
        guard let inbox = inboxURL(fileManager: fileManager, groupID: groupID) else {
            return []
        }
        return pendingFiles(in: inbox, fileManager: fileManager)
    }

    /// Test seam — enumerate a specific directory (no group
    /// container required). The production overload above delegates
    /// here.
    static func pendingFiles(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let allowed: Set<String> = ["epub", "pdf"]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { url in
                guard allowed.contains(url.pathExtension.lowercased()) else { return false }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                if values?.isRegularFile == true { return true }
                return values?.isDirectory == true && EpubDirectoryArchiver.isValidPackage(at: url, fileManager: fileManager)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Drain every pending file in the Inbox into the given library.
    /// After the import attempt the file is deleted regardless of
    /// outcome — we don't want a permanently failing payload to keep
    /// re-importing on every launch. Errors are surfaced via the
    /// returned `ImportOutcome` so callers can show a toast.
    @discardableResult
    static func drain(
        into library: LibraryStore,
        fileManager: FileManager = .default,
        groupID: String = appGroupID
    ) -> [ImportOutcome] {
        let urls = pendingFiles(fileManager: fileManager, groupID: groupID)
        return drain(urls: urls, into: library, fileManager: fileManager)
    }

    /// Test seam — drain an explicit URL list. Same behaviour as the
    /// production overload but accepts URLs taken from a non-group
    /// directory.
    @discardableResult
    static func drain(
        urls: [URL],
        into library: LibraryStore,
        fileManager: FileManager = .default
    ) -> [ImportOutcome] {
        var outcomes: [ImportOutcome] = []
        for url in urls {
            do {
                let book = try library.importBook(from: url)
                outcomes.append(.init(url: url, importedBookID: book.id, error: nil))
            } catch {
                outcomes.append(.init(
                    url: url,
                    importedBookID: nil,
                    error: error.localizedDescription
                ))
            }
            try? fileManager.removeItem(at: url)
        }
        return outcomes
    }

    /// Used by the Share Extension to drop a file into the Inbox.
    /// Returns the destination URL on success. The extension copies
    /// rather than moves because the source URL is owned by the host
    /// app (Books, Files, Safari, …) and may be in a temporary
    /// `NSItemProvider` cache that disappears once the extension
    /// returns.
    @discardableResult
    static func dropIntoInbox(
        source: URL,
        fileManager: FileManager = .default,
        groupID: String = appGroupID
    ) throws -> URL {
        try SharedContainerInbox.dropIntoInbox(
            source: source,
            fileManager: fileManager,
            groupID: groupID
        )
    }

    /// If the chosen filename already exists in the inbox (user shared
    /// two copies of the same book), suffix with `-1`, `-2`, …
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
            if !fileManager.fileExists(atPath: next.path) { return next }
        }
        // Fallback — collision after 999 iterations is implausible
        // but we never want to overwrite a user file.
        return directory.appendingPathComponent("\(UUID().uuidString)-\(filename)")
    }
}
