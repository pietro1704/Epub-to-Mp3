import Foundation
import Compression

/// Generates a tiny, valid EPUB-shaped ZIP archive in a temp file so
/// integration tests can exercise the real `ZipReader` +
/// `EpubMetadataReader` + `LibraryStore` import path without
/// committing a binary fixture into the repo.
///
/// Members:
///   - `mimetype` (STORE) → "application/epub+zip"
///   - `META-INF/container.xml` (DEFLATE) → points at OEBPS/content.opf
///   - `OEBPS/content.opf` (DEFLATE) → dc:title + dc:creator + cover ref
///   - `OEBPS/cover.png` (STORE) → 1×1 PNG bytes
enum EpubFixture {

    static let title = "Test Book Title"
    static let author = "Test Author"
    static let coverPNG: Data = Data([
        // 1×1 transparent PNG, hand-crafted minimum.
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82,
    ])

    static let containerXML = """
    <?xml version="1.0"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """.data(using: .utf8)!

    static let opfXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="bookid">urn:test:book</dc:identifier>
        <dc:title>\(title)</dc:title>
        <dc:creator>\(author)</dc:creator>
        <meta name="cover" content="cover-img"/>
      </metadata>
      <manifest>
        <item id="cover-img" href="cover.png" media-type="image/png" properties="cover-image"/>
      </manifest>
      <spine />
    </package>
    """.data(using: .utf8)!

    /// Build a fresh EPUB at a unique temp path. Caller is responsible
    /// for deleting it (typical pattern: `defer try? FileManager…`).
    static func create() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-\(UUID().uuidString).epub")
        let archive = try buildArchive(members: [
            .stored("mimetype", Data("application/epub+zip".utf8)),
            .deflated("META-INF/container.xml", containerXML),
            .deflated("OEBPS/content.opf", opfXML),
            .stored("OEBPS/cover.png", coverPNG),
        ])
        try archive.write(to: url)
        return url
    }

    /// Build an EPUB that includes one short chapter HTML in the spine
    /// so end-to-end conversion tests (`PythonBridge.convertEpub`) have
    /// real text to synthesise. The plain `create()` path keeps the
    /// metadata-only fixture other tests rely on.
    static func createWithChapter(
        chapterTitle: String = "Chapter 1",
        body: String = "This is a short chapter used for end to end testing."
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-\(UUID().uuidString).epub")

        // EPUB3 spine pointing at a single XHTML file. Keep the markup
        // minimal — `EbookReader` strips boilerplate and reads the text
        // node, so anything we add beyond a paragraph just slows the
        // parser without helping the test.
        let chapterXHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>\(chapterTitle)</title></head>
          <body>
            <h1>\(chapterTitle)</h1>
            <p>\(body)</p>
          </body>
        </html>
        """.data(using: .utf8)!

        let withSpineOPF = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" \
        unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">urn:test:book</dc:identifier>
            <dc:title>\(title)</dc:title>
            <dc:creator>\(author)</dc:creator>
            <dc:language>en</dc:language>
            <meta name="cover" content="cover-img"/>
          </metadata>
          <manifest>
            <item id="cover-img" href="cover.png" media-type="image/png" \
        properties="cover-image"/>
            <item id="ch1" href="chapter1.xhtml" \
        media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="ch1"/>
          </spine>
        </package>
        """.data(using: .utf8)!

        let archive = try buildArchive(members: [
            .stored("mimetype", Data("application/epub+zip".utf8)),
            .deflated("META-INF/container.xml", containerXML),
            .deflated("OEBPS/content.opf", withSpineOPF),
            .deflated("OEBPS/chapter1.xhtml", chapterXHTML),
            .stored("OEBPS/cover.png", coverPNG),
        ])
        try archive.write(to: url)
        return url
    }

    // MARK: - Tiny ZIP writer

    private struct Member {
        let name: String
        let data: Data
        let method: UInt16   // 0 = store, 8 = deflate
        let payload: Data    // already compressed (or raw if stored)
        let crc32: UInt32

        static func stored(_ name: String, _ data: Data) -> Member {
            Member(name: name, data: data, method: 0,
                   payload: data, crc32: crc(data))
        }
        static func deflated(_ name: String, _ data: Data) -> Member {
            Member(name: name, data: data, method: 8,
                   payload: deflate(data), crc32: crc(data))
        }
    }

    private static func buildArchive(members: [Member]) throws -> Data {
        var out = Data()
        var localOffsets: [UInt64] = []

        for m in members {
            localOffsets.append(UInt64(out.count))
            // Local file header
            out.appendUInt32LE(0x04034b50)         // signature
            out.appendUInt16LE(20)                 // version
            out.appendUInt16LE(0)                  // flags
            out.appendUInt16LE(m.method)
            out.appendUInt16LE(0)                  // mod time
            out.appendUInt16LE(0)                  // mod date
            out.appendUInt32LE(m.crc32)
            out.appendUInt32LE(UInt32(m.payload.count))
            out.appendUInt32LE(UInt32(m.data.count))
            let nameBytes = Data(m.name.utf8)
            out.appendUInt16LE(UInt16(nameBytes.count))
            out.appendUInt16LE(0)                  // extra len
            out.append(nameBytes)
            out.append(m.payload)
        }

        let cdStart = UInt64(out.count)
        for (i, m) in members.enumerated() {
            // Central directory header
            out.appendUInt32LE(0x02014b50)         // signature
            out.appendUInt16LE(20)                 // version made by
            out.appendUInt16LE(20)                 // version needed
            out.appendUInt16LE(0)                  // flags
            out.appendUInt16LE(m.method)
            out.appendUInt16LE(0)                  // mod time
            out.appendUInt16LE(0)                  // mod date
            out.appendUInt32LE(m.crc32)
            out.appendUInt32LE(UInt32(m.payload.count))
            out.appendUInt32LE(UInt32(m.data.count))
            let nameBytes = Data(m.name.utf8)
            out.appendUInt16LE(UInt16(nameBytes.count))
            out.appendUInt16LE(0)                  // extra
            out.appendUInt16LE(0)                  // comment
            out.appendUInt16LE(0)                  // disk number
            out.appendUInt16LE(0)                  // internal attrs
            out.appendUInt32LE(0)                  // external attrs
            out.appendUInt32LE(UInt32(localOffsets[i]))
            out.append(nameBytes)
        }
        let cdSize = UInt64(out.count) - cdStart

        // EOCD
        out.appendUInt32LE(0x06054b50)
        out.appendUInt16LE(0)
        out.appendUInt16LE(0)
        out.appendUInt16LE(UInt16(members.count))
        out.appendUInt16LE(UInt16(members.count))
        out.appendUInt32LE(UInt32(cdSize))
        out.appendUInt32LE(UInt32(cdStart))
        out.appendUInt16LE(0)                      // comment len

        return out
    }

    /// Raw DEFLATE — Compression.framework's `COMPRESSION_ZLIB`
    /// produces the same bitstream that real EPUB writers emit and
    /// `ZipReader.inflate` consumes.
    private static func deflate(_ src: Data) -> Data {
        let dstCap = max(src.count + 64, 64)
        var dst = Data(count: dstCap)
        let n = dst.withUnsafeMutableBytes { dstRaw -> Int in
            guard let dstPtr = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return src.withUnsafeBytes { srcRaw -> Int in
                guard let srcPtr = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(
                    dstPtr, dstCap,
                    srcPtr, src.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        return dst.prefix(n)
    }

    private static func crc(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : (crc >> 1)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendUInt16LE(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
    }
    mutating func appendUInt32LE(_ v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 24) & 0xFF))
    }
}
