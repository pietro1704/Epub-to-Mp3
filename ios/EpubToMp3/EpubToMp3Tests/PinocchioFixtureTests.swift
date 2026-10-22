import CryptoKit
import Foundation
import XCTest

final class PinocchioFixtureTests: XCTestCase {
    func testBundledResourcesPreserveTheOriginalMarkupBytes() throws {
        let html = try PinocchioFixture.loadResource(withExtension: "xhtml")
        let css = try PinocchioFixture.loadResource(withExtension: "css")
        XCTAssertEqual(html, PinocchioFixture.chapter3HTML)
        XCTAssertEqual(css, PinocchioFixture.chapter3CSS)
        XCTAssertEqual(digest(html), "6f6b2dfa1f0cfdae2ba238f27d48d307e00db8f8528691ed07be5601bd54e689")
        XCTAssertEqual(digest(css), "e196df26cab031487b0d17ce3ed1b56beb6c1264d9d7b95608bfb660972a531a")
    }

    func testMissingResourceReportsItsLiteralIdentity() {
        XCTAssertThrowsError(try PinocchioFixture.loadResource(named: "missing-chapter", withExtension: "xhtml")) { error in
            XCTAssertEqual(error as? PinocchioFixture.ResourceError, .missingResource("missing-chapter.xhtml"))
        }
    }

    func testInvalidUTF8ResourceFailsInsteadOfSilentlyChangingText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chapter.xhtml")
        try Data([0xff, 0xfe, 0xff]).write(to: url)
        XCTAssertThrowsError(try PinocchioFixture.decodeResource(at: url))
        try Data("recovered text".utf8).write(to: url)
        XCTAssertEqual(try PinocchioFixture.decodeResource(at: url), "recovered text")
    }

    private func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
