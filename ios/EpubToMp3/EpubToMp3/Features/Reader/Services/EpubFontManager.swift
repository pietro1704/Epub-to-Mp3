import Foundation
import CoreText

enum EpubFontManager {

    // Guarded by an internal NSLock so the static dedup set is safe to
    // access from any actor. CTFontManager APIs are also thread-safe;
    // the only piece that needed protection was this bookkeeping set.
    // Swift 6 strict concurrency would otherwise flag the mutable
    // `nonisolated` global.
    private final class RegistrationState: @unchecked Sendable {
        let lock = NSLock()
        var directories: Set<String> = []
    }

    private static let state = RegistrationState()

    private static func hasRegistered(_ key: String) -> Bool {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.directories.contains(key)
    }

    private static func markRegistered(_ key: String) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.directories.insert(key)
    }

    static func registerFonts(from epubURL: URL) -> [URL] {
        guard let entries = ZipReader.listEntries(in: epubURL) else { return [] }

        let fontExtensions: Set<String> = ["otf", "ttf", "woff", "woff2"]
        let fontEntries = entries.filter { entry in
            let ext = (entry as NSString).pathExtension.lowercased()
            return fontExtensions.contains(ext)
        }
        guard !fontEntries.isEmpty else { return [] }

        let bookKey = epubURL.lastPathComponent
        guard !hasRegistered(bookKey) else { return [] }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-fonts-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: tmpDir, withIntermediateDirectories: true)
        } catch {
            return []
        }

        var registered: [URL] = []
        for entry in fontEntries {
            guard let data = ZipReader.extract(member: entry, from: epubURL) else {
                continue
            }
            let filename = (entry as NSString).lastPathComponent
            let fontURL = tmpDir.appendingPathComponent(filename)
            guard (try? data.write(to: fontURL)) != nil else { continue }
            var err: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(
                fontURL as CFURL, .process, &err
            ) {
                registered.append(fontURL)
            } else if let cfErr = err?.takeRetainedValue(),
                      CFErrorGetCode(cfErr) == 105 {
                // kCTFontManagerErrorAlreadyRegistered — silently skip
                registered.append(fontURL)
            }
        }
        if !registered.isEmpty { markRegistered(bookKey) }
        return registered
    }

    static func unregisterFonts(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        for url in urls {
            var err: Unmanaged<CFError>?
            CTFontManagerUnregisterFontsForURL(url as CFURL, .process, &err)
        }
        if let first = urls.first {
            let dir = first.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
