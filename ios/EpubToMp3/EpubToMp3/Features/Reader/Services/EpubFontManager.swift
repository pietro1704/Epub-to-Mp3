import Foundation
import CoreText

/// Extracts EPUB fonts once into durable reader storage and registers them
/// for the current process. The reader cache can therefore reopen a book
/// without its security-scoped source URL while preserving its CSS fonts.
enum EpubFontManager {

    // Guarded by an internal NSLock so the registration cache is safe to
    // access from any actor. Core Text registration itself is thread-safe.
    private final class RegistrationState: @unchecked Sendable {
        let lock = NSLock()
        var urlsByBookID: [String: [URL]] = [:]
    }

    private static let state = RegistrationState()
    private static let fontExtensions: Set<String> = ["otf", "ttf", "woff", "woff2"]

    /// Compatibility entry point for callers that do not yet have a stable
    /// library identifier. Reader opens should always provide `bookID`.
    static func registerFonts(from epubURL: URL) -> [URL] {
        registerFonts(from: epubURL, bookID: epubURL.lastPathComponent)
    }

    static func registerFonts(from epubURL: URL, bookID: String) -> [URL] {
        if let registered = registeredURLs(bookID: bookID) {
            return registered
        }

        let directory = persistentDirectory(bookID: bookID)
        let cachedURLs = fontURLs(in: directory)
        if !cachedURLs.isEmpty {
            return register(fontURLs: cachedURLs, bookID: bookID)
        }

        guard let entries = ZipReader.listEntries(in: epubURL) else { return [] }
        let fontEntries = entries.filter { entry in
            fontExtensions.contains((entry as NSString).pathExtension.lowercased())
        }
        guard !fontEntries.isEmpty, let directory else { return [] }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in fontEntries {
            guard let data = ZipReader.extract(member: entry, from: epubURL) else { continue }
            // EPUB resources commonly live in separate folders but CSS refers
            // to their basename. Keep the existing renderer contract while
            // avoiding an overwrite when two resources share that basename.
            let originalName = (entry as NSString).lastPathComponent
            let destination = uniqueURL(named: originalName, in: directory)
            try? data.write(to: destination, options: .atomic)
        }
        return register(fontURLs: fontURLs(in: directory), bookID: bookID)
    }

    /// Registers fonts previously extracted by a cold reader open. This path
    /// never touches the EPUB bookmark and is safe during warm restoration.
    static func registerCachedFonts(bookID: String) -> [URL] {
        if let registered = registeredURLs(bookID: bookID) {
            return registered
        }
        return register(fontURLs: fontURLs(in: persistentDirectory(bookID: bookID)), bookID: bookID)
    }

    static func unregisterFonts(_ urls: [URL]) {
        for url in urls {
            var error: Unmanaged<CFError>?
            CTFontManagerUnregisterFontsForURL(url as CFURL, .process, &error)
        }
    }

    /// Removes durable extracted font resources with their source book. Core
    /// Text may keep an in-process registration alive until app exit, but no
    /// reader cache or storage survives the listener's explicit removal.
    static func evictCachedFonts(bookID: String) {
        state.lock.lock()
        state.urlsByBookID.removeValue(forKey: bookID)
        state.lock.unlock()
        guard let directory = persistentDirectory(bookID: bookID) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func registeredURLs(bookID: String) -> [URL]? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.urlsByBookID[bookID]
    }

    private static func register(fontURLs: [URL], bookID: String) -> [URL] {
        guard !fontURLs.isEmpty else { return [] }
        var registered: [URL] = []
        for url in fontURLs {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                registered.append(url)
            } else if let coreTextError = error?.takeRetainedValue(),
                      CFErrorGetCode(coreTextError) == 105 {
                // kCTFontManagerErrorAlreadyRegistered still leaves the font
                // usable by the renderer in this process.
                registered.append(url)
            }
        }
        state.lock.lock()
        state.urlsByBookID[bookID] = registered
        state.lock.unlock()
        return registered
    }

    private static func persistentDirectory(bookID: String) -> URL? {
        guard let applicationSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let safeBookID = bookID.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        guard !safeBookID.isEmpty else { return nil }
        return applicationSupport
            .appendingPathComponent("EpubToMp3", isDirectory: true)
            .appendingPathComponent("ReaderFonts-v1", isDirectory: true)
            .appendingPathComponent(safeBookID, isDirectory: true)
    }

    private static func fontURLs(in directory: URL?) -> [URL] {
        guard let directory,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return entries.filter { fontExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func uniqueURL(named name: String, in directory: URL) -> URL {
        let original = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: original.path) else { return original }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var suffix = 2
        while true {
            let candidate = directory.appendingPathComponent("\(base)-\(suffix).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }
}
