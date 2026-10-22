import Foundation

enum LibraryBookmarkAccess {
    // MARK: - Bookmark helpers

    private static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        // We may hold a non-security-scoped bookmark when the app is
        // running unsigned (Debug builds) — the system lets us resolve
        // either kind with the same call when we leave the option off.
        // We try the scoped resolution first via the resolver below.
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    /// Best-effort bookmark creation. macOS sandbox + signed app →
    /// security-scoped bookmark. Unsigned Debug runs (no sandbox) →
    /// regular bookmark. iOS → `suitableForBookmarkFile`. We always
    /// return *something* the user can resolve next launch.
    static func makeBookmark(for url: URL) throws -> Data {
        #if os(macOS)
        if let scoped = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return scoped
        }
        return try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #else
        return try url.bookmarkData(
            options: [.suitableForBookmarkFile],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #endif
    }

    /// `URL(resolvingBookmarkData:)` is a synchronous, non-cancellable
    /// system call. For a bookmark pointing at an iCloud-backed file that
    /// isn't downloaded locally, resolution can stall for a long time (or
    /// indefinitely on a bad connection) waiting on the download —
    /// blocking whichever thread called it. `openBookFile` runs inside
    /// `BookOpenScreenController.loadBook()`'s `Task { }`, which — created
    /// from a `@MainActor` method — inherits MainActor isolation, so a
    /// stuck resolve here froze the entire app, not just the reader's
    /// spinner ("carregamento infinito"). Bound it with a hard deadline:
    /// still blocks the calling thread for that window (this API can't be
    /// cancelled), but guarantees the caller gets control back and can
    /// surface a real error instead of hanging forever.
    static func resolveBookmarkWithTimeout(
        _ bookmark: Data,
        options: URL.BookmarkResolutionOptions,
        timeout: TimeInterval = 10
    ) throws -> BookmarkResolution {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResolveResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            var stale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: options,
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                box.result = .success(BookmarkResolution(url: url, stale: stale))
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw NSError(
                domain: "LibraryStore",
                code: 408,
                userInfo: [NSLocalizedDescriptionKey:
                    "Timed out opening this book's file — it may be stuck downloading from iCloud. Check your connection and try again."]
            )
        }
        guard let result = box.result else {
            throw NSError(domain: "LibraryStore", code: 500,
                          userInfo: [NSLocalizedDescriptionKey: "Bookmark resolution finished without a result."])
        }
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    static func resolveBookmarkWithTimeoutAsync(
        _ bookmark: Data,
        options: URL.BookmarkResolutionOptions,
        timeout: TimeInterval = 10
    ) async throws -> BookmarkResolution {
        try await Task.detached(priority: .userInitiated) {
            try Self.resolveBookmarkWithTimeout(
                bookmark,
                options: options,
                timeout: timeout
            )
        }.value
    }

    /// Prefer scoped bookmarks on macOS, retaining unsigned-build compatibility.
    static func resolveBookBookmark(_ bookmark: Data) throws -> BookmarkResolution {
        #if os(macOS)
        if let scoped = try? resolveBookmarkWithTimeout(bookmark, options: [.withSecurityScope]) {
            return scoped
        }
        #endif
        return try resolveBookmarkWithTimeout(bookmark, options: [])
    }

    static func resolveBookBookmarkAsync(_ bookmark: Data) async throws -> BookmarkResolution {
        #if os(macOS)
        if let scoped = try? await resolveBookmarkWithTimeoutAsync(bookmark, options: [.withSecurityScope]) {
            return scoped
        }
        #endif
        return try await resolveBookmarkWithTimeoutAsync(bookmark, options: [])
    }

}

/// Cross-thread result box for `resolveBookmarkWithTimeout` — the
/// resolution work runs on `DispatchQueue.global()` while the caller waits
/// on a semaphore, so the result needs a `Sendable` carrier between them.
struct BookmarkResolution: Sendable {
    let url: URL
    let stale: Bool
}

private final class ResolveResultBox: @unchecked Sendable {
    var result: Result<BookmarkResolution, Error>?
}
