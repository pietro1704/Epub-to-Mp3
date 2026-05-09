import XCTest
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
}
