import XCTest
import zlib
@testable import EpubToMp3

final class EpubMetadataReaderTests: XCTestCase {

    func testParsesContainerXMLToOPFPath() {
        let xml = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        let path = EpubMetadataReader.parseOPFPath(in: xml.data(using: .utf8)!)
        XCTAssertEqual(path, "OEBPS/content.opf")
    }

    func testParsesContainerXMLWithSingleQuotes() {
        // Some EPUB writers use single quotes; the regex requires
        // double quotes so this should return nil. We document the
        // current behaviour so the test catches a future change.
        let xml = "<rootfile full-path='content.opf'/>"
        XCTAssertNil(EpubMetadataReader.parseOPFPath(in: xml.data(using: .utf8)!))
    }

    func testParsesOPFTitleAndCreator() {
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Foundation</dc:title>
            <dc:creator>Isaac Asimov</dc:creator>
            <meta name="cover" content="cover-img"/>
          </metadata>
          <manifest>
            <item id="cover-img" href="images/cover.jpg" media-type="image/jpeg"/>
          </manifest>
        </package>
        """
        let parsed = EpubMetadataReader.parseOPF(data: opf.data(using: .utf8)!)
        XCTAssertEqual(parsed.title, "Foundation")
        XCTAssertEqual(parsed.author, "Isaac Asimov")
        XCTAssertEqual(parsed.coverHref, "images/cover.jpg")
    }

    func testParsesOPFCoverViaPropertiesAttribute() {
        // EPUB 3 spec form: cover image identified via
        // `<item properties="cover-image">` on the manifest entry.
        let opf = """
        <package version="3.0" xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Hobbit</dc:title>
          </metadata>
          <manifest>
            <item id="x" href="cover.png" media-type="image/png" properties="cover-image"/>
          </manifest>
        </package>
        """
        let parsed = EpubMetadataReader.parseOPF(data: opf.data(using: .utf8)!)
        XCTAssertEqual(parsed.coverHref, "cover.png")
    }

    // MARK: - Device vs Simulator parity: raw-DEFLATE ZipReader

    /// Regression test for the real-device "container malformed" failure.
    ///
    /// Root cause: `ZipReader.inflate` previously used
    /// `compression_decode_buffer(…, COMPRESSION_ZLIB)`, which expects a
    /// zlib-wrapped stream (RFC 1950). ZIP method-8 is raw DEFLATE
    /// (RFC 1951, no header/trailer). On the Simulator the Apple
    /// Compression backend tolerates the mismatch; on a real device ARM
    /// hardware acceleration enforces the spec and returns 0 bytes —
    /// every DEFLATE entry silently becomes nil, so `container.xml`
    /// can't be read and the EPUB is reported as malformed.
    ///
    /// This test builds the raw-DEFLATE stream with `deflateInit2(-15)`
    /// (the same code path `EpubFixture` now uses) and verifies
    /// `ZipReader` can round-trip it. If we regress to COMPRESSION_ZLIB
    /// the inflate will produce nil and the extract assertion fails.
    func testZipReaderInflatesRawDeflateCorrectly() throws {
        let url = try EpubFixture.create()
        defer { try? FileManager.default.removeItem(at: url) }

        // The fixture uses raw-DEFLATE for META-INF/container.xml; if
        // we can extract it we know both the fixture generator and the
        // ZipReader are using the same raw-DEFLATE codec.
        let extracted = ZipReader.extract(member: "META-INF/container.xml", from: url)
        XCTAssertNotNil(
            extracted,
            "ZipReader returned nil for deflated container.xml — COMPRESSION_ZLIB regression?"
        )
        XCTAssertTrue(
            String(data: extracted!, encoding: .utf8)?.contains("OEBPS/content.opf") == true,
            "container.xml content corrupted after inflate"
        )
    }

    /// EPUBs produced by some tools (e.g. older Sigil, Kindlegen export)
    /// append a ZIP comment after the EOCD record. The comment can be up
    /// to 65535 bytes long. A naive EOCD scanner that only checks the
    /// last 22 bytes fails to find the signature. Our reverse-scan
    /// implementation searches up to 22 + 65535 bytes from EOF.
    func testZipReaderFindsEOCDWithCommentField() throws {
        var archiveData = try Data(contentsOf: EpubFixture.create())

        // Append a 200-byte comment and update the EOCD comment-length
        // field. The EOCD sits at the 22 bytes before EOF in the
        // original fixture (comment len = 0).
        let eocdOffset = archiveData.count - 22

        // Sanity check: verify signature before patching.
        let sig: UInt32 = archiveData.withUnsafeBytes {
            $0.load(fromByteOffset: eocdOffset, as: UInt32.self)
        }
        // Little-endian 0x06054b50 as stored in memory on any platform.
        let expectedLE = UInt32(0x50).bigEndian == 0x50
            ? UInt32(0x06054b50)   // already LE (little-endian host)
            : UInt32(0x06054b50).byteSwapped
        XCTAssertEqual(sig, expectedLE,
                       "EOCD signature not found at expected offset in fixture")

        let commentLen: UInt16 = 200
        archiveData[eocdOffset + 20] = UInt8(commentLen & 0xFF)
        archiveData[eocdOffset + 21] = UInt8((commentLen >> 8) & 0xFF)
        archiveData.append(Data(repeating: 0x42, count: Int(commentLen)))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("comment-epub-\(UUID().uuidString).epub")
        try archiveData.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let extracted = ZipReader.extract(member: "META-INF/container.xml", from: url)
        XCTAssertNotNil(extracted,
            "ZipReader must find EOCD via reverse scan when comment field is present")
    }

    /// Passing a non-ZIP file must not crash and must return nil gracefully.
    func testZipReaderGracefullyHandlesNonZipFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-zip-\(UUID().uuidString).epub")
        try Data("random garbage data that is definitely not a ZIP archive".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // Must not crash or throw.
        let result = ZipReader.extract(member: "META-INF/container.xml", from: url)
        XCTAssertNil(result, "non-ZIP file must return nil, not crash")

        // EpubMetadataReader must also handle this gracefully.
        let payload = try EpubMetadataReader.readMetadata(from: url)
        XCTAssertNil(payload.title)
        XCTAssertNil(payload.author)
    }
}
