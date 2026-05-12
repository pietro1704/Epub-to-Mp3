import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Centralises drag-and-drop EPUB ingestion for `LibraryView` and
/// `LibrarySidebar`. Both views accept providers of `.epub` (Apple's
/// UTI for EPUB documents) and the legacy IDPF identifier, plus
/// (macOS only) generic file URLs — Finder advertises EPUBs that way
/// when the system hasn't matched the UTI for the user's file
/// extension.
///
/// The handler runs each provider in parallel, loads its file
/// representation, imports it into the library store, and finally
/// reports the first error (if any) back on the main thread so
/// callers can surface it through their existing alert state.
enum LibraryDropHandler {
    /// Accepted UTIs for drop operations. Mirror the file-importer
    /// list, with the macOS-only `.fileURL` fallback bolted on.
    static var acceptedTypes: [UTType] {
        var types: [UTType] = [.epub]
        if let zip = UTType("org.idpf.epub-container") {
            types.append(zip)
        }
        #if os(macOS)
        types.append(.fileURL)
        #endif
        return types
    }

    /// Identifiers we will actively try to load from a provider. Order
    /// matters: prefer the strongest identifier (`.epub`) before
    /// falling back to the legacy IDPF type or the generic file URL.
    static var loadableIdentifiers: [String] {
        var ids: [String] = [UTType.epub.identifier, "org.idpf.epub-container"]
        #if os(macOS)
        ids.append(UTType.fileURL.identifier)
        #endif
        return ids
    }

    /// Imports every supported provider in `providers` by calling
    /// `importer(url)` exactly once per loadable URL. Unsupported
    /// providers are ignored silently — they never appear in the
    /// error report so the user isn't yelled at for stray drops.
    ///
    /// The completion fires on the main thread once every provider
    /// has resolved (success, failure, or unsupported).
    static func handle(
        providers: [NSItemProvider],
        importer: @escaping (URL) throws -> Void,
        completion: @escaping (_ firstError: String?, _ imported: Int) -> Void
    ) -> Bool {
        // Filter to providers we have any hope of loading. Returning
        // `false` lets SwiftUI know the drop wasn't accepted, so the
        // OS will show the standard "cannot drop" cursor.
        let usable = providers.filter { provider in
            loadableIdentifiers.contains { provider.hasItemConformingToTypeIdentifier($0) }
        }
        if usable.isEmpty {
            DispatchQueue.main.async { completion(nil, 0) }
            return false
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var firstError: String?
        var imported = 0

        for provider in usable {
            group.enter()
            load(provider: provider) { result in
                switch result {
                case .success(let url):
                    do {
                        try importer(url)
                        lock.lock(); imported += 1; lock.unlock()
                    } catch {
                        lock.lock()
                        if firstError == nil { firstError = error.localizedDescription }
                        lock.unlock()
                    }
                case .failure(let error):
                    lock.lock()
                    if firstError == nil { firstError = error.localizedDescription }
                    lock.unlock()
                case .unsupported:
                    break
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(firstError, imported)
        }
        return true
    }

    // MARK: - Provider loading

    enum LoadOutcome {
        case success(URL)
        case failure(Error)
        case unsupported
    }

    /// Resolves a single provider into a URL we can hand to
    /// `LibraryStore.importBook(from:)`. Uses
    /// `loadFileRepresentation` for typed payloads (the system gives
    /// us a temp file we can read inside the callback) and falls back
    /// to `loadItem` for file URL providers on macOS.
    ///
    /// The temp URL handed back by `loadFileRepresentation` is only
    /// valid for the duration of the callback — we copy it into our
    /// own scratch directory so the importer can read it on a later
    /// hop without races.
    static func load(
        provider: NSItemProvider,
        completion: @escaping (LoadOutcome) -> Void
    ) {
        let preferredIDs = loadableIdentifiers.filter {
            provider.hasItemConformingToTypeIdentifier($0)
        }
        guard let id = preferredIDs.first else {
            completion(.unsupported)
            return
        }

        // Generic file URL (macOS Finder drag) — load via loadItem so
        // we get the original on-disk URL instead of a temp copy.
        if id == UTType.fileURL.identifier {
            provider.loadItem(forTypeIdentifier: id, options: nil) { item, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }
                if let url = item as? URL {
                    completion(.success(url))
                } else if let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) {
                    completion(.success(url))
                } else {
                    completion(.unsupported)
                }
            }
            return
        }

        // EPUB payload — `loadFileRepresentation` gives us a temp URL
        // that lives only for the duration of the callback. Copy it
        // into our own scratch dir so the importer can still read it
        // when the main-thread hop fires.
        provider.loadFileRepresentation(forTypeIdentifier: id) { url, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let url = url else {
                completion(.unsupported)
                return
            }
            do {
                let scratch = try copyToScratch(url)
                completion(.success(scratch))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Copies `source` into a deterministic per-process scratch dir
    /// so the URL stays valid after `loadFileRepresentation`'s
    /// callback returns. `LibraryStore.importBook` hashes the file
    /// contents (the de-dup key), so even if the scratch copy is
    /// removed later the library entry survives.
    static func copyToScratch(_ source: URL) throws -> URL {
        let dir = scratchDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(
            "\(UUID().uuidString)-\(source.lastPathComponent)"
        )
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    static var scratchDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("EpubToMp3-Drop", isDirectory: true)
    }
}

// MARK: - Visual feedback

/// Dashed overlay shown when a drag enters one of the library
/// surfaces. Reused by both `LibraryView` and `LibrarySidebar` so the
/// affordance is identical on phone, iPad, and macOS.
struct DropTargetOverlay: View {
    let isActive: Bool

    var body: some View {
        if isActive {
            ZStack {
                Color.accentColor.opacity(0.06)
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                    )
                    .foregroundStyle(Color.accentColor)
                    .padding(8)
                Label("Drop EPUB here", systemImage: "tray.and.arrow.down")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
            }
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityIdentifier("library.dropOverlay")
        }
    }
}
