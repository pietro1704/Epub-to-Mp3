import Foundation
import XCTest

/// Real chapter HTML + CSS pulled from the Pinocchio EPUB the user
/// reads on-device (Project Gutenberg Ebookmaker output), so reader
/// formatting tests run against the ACTUAL book markup, not a
/// synthetic fixture. Body <p> are text-align:justify; the chapter
/// title is an <h2>. There are NO class="center" paragraphs in the body.
enum PinocchioFixture {
    static let chapter3HTML = requiredResource(withExtension: "xhtml")
    static let chapter3CSS = requiredResource(withExtension: "css")

    enum ResourceError: Error, Equatable {
        case missingResource(String)
    }

    static func loadResource(
        named name: String = "chapter-3",
        withExtension type: String,
        bundle: Bundle = Bundle(for: PinocchioFixtureBundleAnchor.self)
    ) throws -> String {
        guard let url = bundle.url(forResource: name, withExtension: type, subdirectory: "Pinocchio") else {
            throw ResourceError.missingResource("\(name).\(type)")
        }
        return try decodeResource(at: url)
    }

    static func decodeResource(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private static func requiredResource(withExtension type: String) -> String {
        do {
            return try loadResource(withExtension: type)
        } catch {
            XCTFail("Cannot load the bundled Pinocchio \(type) fixture: \(error)")
            return ""
        }
    }
}

private final class PinocchioFixtureBundleAnchor: NSObject {}
