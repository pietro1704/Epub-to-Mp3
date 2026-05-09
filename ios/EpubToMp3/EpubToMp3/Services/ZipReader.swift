import Foundation
import Compression

/// Minimal in-process ZIP reader sufficient for EPUB metadata extraction.
///
/// Why not shell out to `/usr/bin/unzip`?
///   - Under macOS App Sandbox, the user-picked EPUB is only readable
///     while the parent process holds an active security-scoped
///     resource. `Process` spawns a fresh subprocess that does NOT
///     inherit the security-scoped access, so `unzip` fails with
///     "couldn't be opened" on every sandboxed import.
///   - iOS has no `/usr/bin/unzip` at all.
///
/// Scope: supports STORE (method 0) and DEFLATE (method 8) — the only
/// two methods used by every real EPUB. ZIP64 archives are out of
/// scope (an EPUB is rarely > 4 GB). Encrypted entries are out of
/// scope. Any unsupported entry returns nil rather than throwing —
/// the caller treats missing metadata as best-effort.
enum ZipReader {

    /// Extract a single named entry from the archive. Returns nil if
    /// the entry doesn't exist or its compression method is unsupported.
    static func extract(member: String, from archiveURL: URL) -> Data? {
        guard let archive = try? Data(contentsOf: archiveURL,
                                      options: [.alwaysMapped]) else {
            return nil
        }
        guard let centralDirectory = locateCentralDirectory(in: archive) else {
            return nil
        }
        let entries = parseCentralDirectory(archive: archive,
                                            offset: centralDirectory.offset,
                                            count: centralDirectory.entryCount)
        guard let entry = entries.first(where: { $0.name == member }) else {
            return nil
        }
        return readLocalFile(archive: archive, entry: entry)
    }

    // MARK: - Central directory

    private struct CentralDirectoryHeader {
        let offset: UInt64       // start of central directory bytes
        let entryCount: Int
    }

    private struct Entry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
    }

    /// Walk backwards from EOF to find the End-Of-Central-Directory
    /// signature (0x06054b50). Comment field can be up to 65535 bytes
    /// so we cap the search.
    private static func locateCentralDirectory(in archive: Data) -> CentralDirectoryHeader? {
        let eocdSig: UInt32 = 0x06054b50
        let minEocdSize = 22
        let count = archive.count
        guard count >= minEocdSize else { return nil }
        let searchFrom = max(0, count - minEocdSize - 0xFFFF)
        var i = count - minEocdSize
        while i >= searchFrom {
            if archive.readUInt32LE(at: i) == eocdSig {
                let entries = Int(archive.readUInt16LE(at: i + 10))
                let cdOffset = UInt64(archive.readUInt32LE(at: i + 16))
                if cdOffset == 0xFFFFFFFF {
                    // ZIP64 — out of scope for now.
                    return nil
                }
                return CentralDirectoryHeader(offset: cdOffset, entryCount: entries)
            }
            i -= 1
        }
        return nil
    }

    private static func parseCentralDirectory(
        archive: Data,
        offset: UInt64,
        count: Int
    ) -> [Entry] {
        var entries: [Entry] = []
        var pos = Int(offset)
        for _ in 0..<count {
            guard pos + 46 <= archive.count else { break }
            let sig = archive.readUInt32LE(at: pos)
            guard sig == 0x02014b50 else { break }
            let method = archive.readUInt16LE(at: pos + 10)
            let compSize = UInt64(archive.readUInt32LE(at: pos + 20))
            let uncompSize = UInt64(archive.readUInt32LE(at: pos + 24))
            let nameLen = Int(archive.readUInt16LE(at: pos + 28))
            let extraLen = Int(archive.readUInt16LE(at: pos + 30))
            let commentLen = Int(archive.readUInt16LE(at: pos + 32))
            let localOffset = UInt64(archive.readUInt32LE(at: pos + 42))

            let nameStart = pos + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= archive.count else { break }
            let nameData = archive.subdata(in: nameStart..<nameEnd)
            let name = String(data: nameData, encoding: .utf8) ?? ""

            entries.append(Entry(
                name: name,
                compressionMethod: method,
                compressedSize: compSize,
                uncompressedSize: uncompSize,
                localHeaderOffset: localOffset
            ))
            pos = nameEnd + extraLen + commentLen
        }
        return entries
    }

    /// Read the data block for one entry. Local file header is parsed
    /// to skip name + extra fields, then the compressed bytes are
    /// inflated (if needed) into a Data buffer.
    private static func readLocalFile(archive: Data, entry: Entry) -> Data? {
        let pos = Int(entry.localHeaderOffset)
        guard pos + 30 <= archive.count else { return nil }
        guard archive.readUInt32LE(at: pos) == 0x04034b50 else { return nil }
        let nameLen = Int(archive.readUInt16LE(at: pos + 26))
        let extraLen = Int(archive.readUInt16LE(at: pos + 28))
        let dataStart = pos + 30 + nameLen + extraLen
        let dataEnd = dataStart + Int(entry.compressedSize)
        guard dataEnd <= archive.count else { return nil }
        let compressed = archive.subdata(in: dataStart..<dataEnd)

        switch entry.compressionMethod {
        case 0:
            return compressed
        case 8:
            return inflate(deflated: compressed,
                           expectedSize: Int(entry.uncompressedSize))
        default:
            return nil
        }
    }

    /// Wraps `compression_decode_buffer` with the raw-DEFLATE algorithm.
    /// `expectedSize` is the central-directory advertised size; we use
    /// it as the destination buffer capacity. If the actual stream is
    /// larger (rare — would imply a malformed entry), the call returns
    /// the bytes that fit and `expectedSize` matches typical EPUBs
    /// exactly.
    private static func inflate(deflated: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        var dst = Data(count: expectedSize)
        let n = dst.withUnsafeMutableBytes { dstRaw -> Int in
            guard let dstPtr = dstRaw.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return deflated.withUnsafeBytes { srcRaw -> Int in
                guard let srcPtr = srcRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    dstPtr, expectedSize,
                    srcPtr, deflated.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard n > 0 else { return nil }
        return dst.prefix(n)
    }
}

// MARK: - Little-endian helpers

private extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        let b0 = UInt16(self[startIndex + offset])
        let b1 = UInt16(self[startIndex + offset + 1])
        return b0 | (b1 << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let b0 = UInt32(self[startIndex + offset])
        let b1 = UInt32(self[startIndex + offset + 1])
        let b2 = UInt32(self[startIndex + offset + 2])
        let b3 = UInt32(self[startIndex + offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}
