import Foundation

/// File IO is isolated from playback/UI state and serialized per player.
actor SegmentFileWriter {
    private let write: @Sendable (Data, URL) throws -> Void

    init(write: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
        try data.write(to: url)
    }) {
        self.write = write
    }

    func persist(_ data: Data, to url: URL) throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        do {
            try write(data, url)
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
