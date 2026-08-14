import XCTest
@testable import EpubToMp3

final class EpubDirectoryArchiverSecurityTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-archiver-security-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testRejectsOPFPathTraversalOutsidePackage() throws {
        let package = try makePackage(named: "Traversal.epub", opfPath: "../../outside.opf")
        try Data("outside".utf8).write(to: temporaryDirectory.appendingPathComponent("outside.opf"))

        XCTAssertFalse(EpubDirectoryArchiver.isValidPackage(at: package))
        XCTAssertThrowsError(try EpubDirectoryArchiver.materializeIfNeeded(at: package))
    }

    func testRejectsOPFSymlinkOutsidePackage() throws {
        let package = try makePackage(named: "Symlink.epub", opfPath: "OEBPS/content.opf", writeOPF: false)
        let outside = temporaryDirectory.appendingPathComponent("outside.opf")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: package.appendingPathComponent("OEBPS/content.opf"),
            withDestinationURL: outside
        )

        XCTAssertFalse(EpubDirectoryArchiver.isValidPackage(at: package))
        XCTAssertThrowsError(try EpubDirectoryArchiver.materializeIfNeeded(at: package))
    }

    private func makePackage(
        named name: String,
        opfPath: String,
        writeOPF: Bool = true
    ) throws -> URL {
        let package = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        let metaInf = package.appendingPathComponent("META-INF", isDirectory: true)
        let oebps = package.appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)
        try Data("application/epub+zip".utf8).write(to: package.appendingPathComponent("mimetype"))
        let container = """
        <?xml version="1.0"?>
        <container><rootfiles><rootfile full-path="\(opfPath)" /></rootfiles></container>
        """
        try Data(container.utf8).write(to: metaInf.appendingPathComponent("container.xml"))
        if writeOPF {
            try Data("<package/>".utf8).write(to: package.appendingPathComponent(opfPath))
        }
        return package
    }
}
