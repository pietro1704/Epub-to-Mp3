import AVFoundation
import CryptoKit
import Foundation

/// File checks for copy-only import. This never finalizes or rewrites source audio.
enum LocalAudioImportFiles {
    enum Failure: Error {
        case invalidIdentity
        case unsafePath
        case sourceChanged
        case invalidAudio
        case destinationConflict
    }

    struct Fingerprint: Equatable {
        let digest: SHA256.Digest
        let byteCount: Int64

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.byteCount == rhs.byteCount && Array(lhs.digest) == Array(rhs.digest)
        }
    }

    static func isComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    /// Permit an absent destination, but never follow a symlink inside either root.
    static func checkPath(_ url: URL, under root: URL) throws {
        let root = root.standardizedFileURL
        var cursor = url.standardizedFileURL
        guard cursor.path == root.path || cursor.path.hasPrefix(root.path + "/") else {
            throw Failure.unsafePath
        }
        while true {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: cursor.path)
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    throw Failure.unsafePath
                }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
                // Missing descendants are created only after the whole chain is checked.
            }
            if cursor.path == root.path { return }
            cursor.deleteLastPathComponent()
        }
    }

    static func requireRegularFile(_ url: URL, under root: URL) throws {
        try checkPath(url, under: root)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw Failure.unsafePath
        }
    }

    /// Bounded memory, with cancellation between reads even for whole-book audio.
    static func fingerprint(
        _ source: URL, copyingTo destination: URL? = nil,
        onCopiedBytes: (Int64) -> Void = { _ in }
    ) throws -> Fingerprint {
        try Task.checkCancellation()
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try destination.map { url -> FileHandle in
            try Data().write(to: url, options: .withoutOverwriting)
            return try FileHandle(forWritingTo: url)
        }
        defer { try? output?.close() }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let bytes = try input.read(upToCount: 256 * 1024), !bytes.isEmpty else { break }
            try output?.write(contentsOf: bytes)
            hasher.update(data: bytes)
            byteCount += Int64(bytes.count)
            if output != nil { onCopiedBytes(byteCount) }
        }
        try output?.synchronize()
        return Fingerprint(digest: hasher.finalize(), byteCount: byteCount)
    }

    /// Decode through EOF with bounded memory; a playable prefix is not enough.
    /// Synchronous decoding keeps actor publication non-reentrant and does not
    /// start playback or acquire an audio session.
    static func validateAudio(_ url: URL, onDecodedFrames: (Int64) -> Void = { _ in }) throws {
        try Task.checkCancellation()
        do {
            let audio = try AVAudioFile(forReading: url)
            let sampleRate = audio.processingFormat.sampleRate
            let expectedFrames = audio.length
            let duration = Double(expectedFrames) / sampleRate
            guard sampleRate.isFinite, sampleRate > 0, duration.isFinite, duration > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096) else {
                throw Failure.invalidAudio
            }
            var decodedFrames: Int64 = 0
            // AVAudioFile can throw nilError on a read beyond the declared EOF
            // of a valid MP3. Decode every declared frame, without that extra read.
            while decodedFrames < expectedFrames {
                try Task.checkCancellation()
                let remaining = AVAudioFrameCount(min(4096, expectedFrames - decodedFrames))
                try audio.read(into: buffer, frameCount: remaining)
                guard buffer.frameLength > 0 else { throw Failure.invalidAudio }
                let (total, overflow) = decodedFrames.addingReportingOverflow(Int64(buffer.frameLength))
                guard !overflow, total <= expectedFrames else { throw Failure.invalidAudio }
                decodedFrames = total
                onDecodedFrames(decodedFrames)
            }
            let decodedDuration = Double(decodedFrames) / sampleRate
            guard decodedFrames == expectedFrames, decodedDuration.isFinite, decodedDuration > 0 else {
                throw Failure.invalidAudio
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.invalidAudio
        }
        try Task.checkCancellation()
    }
}
