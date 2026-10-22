import Darwin
import XCTest
@testable import EpubToMp3

final class ConverterFFIStringOwnershipTests: XCTestCase {
    func testMetadataConversionAndErrorStringsAreFreedExactlyOnceIncludingMalformedUTF8() throws {
        let executable = try XCTUnwrap(Bundle(for: Self.self).executableURL)
        let handle = try XCTUnwrap(dlopen(executable.path, RTLD_NOW | RTLD_LOCAL))
        defer { dlclose(handle) }
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            unsafeBitCast(try XCTUnwrap(dlsym(handle, name)), to: type)
        }
        let reset = try symbol("converter_fixture_reset", as: (@convention(c) (Int32) -> Void).self)
        let live = try symbol("converter_fixture_live_strings", as: (@convention(c) () -> Int32).self)
        let freed = try symbol("converter_fixture_freed_strings", as: (@convention(c) () -> Int32).self)
        let invalid = try symbol("converter_fixture_invalid_frees", as: (@convention(c) () -> Int32).self)
        let closed = try symbol("converter_fixture_closed_sessions", as: (@convention(c) () -> Int32).self)
        defer { reset(0) }
        let adapter = ConverterFFIAdapter(libraryURL: executable)
        let book = URL(fileURLWithPath: "/fixture/book.epub")
        reset(0)
        let metadata = try adapter.openBook(at: book).metadataJSON
        XCTAssertEqual(try JSONSerialization.jsonObject(with: metadata) as? [String: String], ["book_id": "fixture-book"])
        XCTAssertEqual(freed(), 1)
        XCTAssertEqual(live(), 0)
        XCTAssertEqual(closed(), 1)
        XCTAssertEqual(invalid(), 0)

        for mode: Int32 in 1...4 {
            reset(mode)
            XCTAssertThrowsError(try adapter.openBook(at: book)) { error in
                let reason = mode == 3 ? "unknown converter-ffi error" : "fixture failed"
                XCTAssertEqual(error as? EmbeddedConverterError, .conversionFailed(reason))
            }
            XCTAssertEqual(live(), 0, "Leaked owned C string for fixture mode \(mode)")
            XCTAssertEqual(freed(), mode == 1 ? 2 : 1)
            XCTAssertEqual(closed(), mode <= 2 ? 1 : 0)
            XCTAssertEqual(invalid(), 0, "Freed a missing, unrelated or already-freed pointer")
        }

        let output = URL(fileURLWithPath: "/fixture/output")
        for mode: Int32 in 0...4 {
            reset(mode)
            if mode == 0 {
                let data = try adapter.convertBook(at: book, outputDirectory: output, jobID: "fixture-job")
                let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual((envelope["manifest"] as? [String: String])?["jobId"], "fixture-job")
            } else {
                XCTAssertThrowsError(try adapter.convertBook(at: book, outputDirectory: output, jobID: "fixture-job")) { error in
                    let reason: String
                    switch mode {
                    case 1: reason = "Rust returned invalid UTF-8 manifest JSON."
                    case 3: reason = "unknown converter-ffi error"
                    default: reason = "fixture failed"
                    }
                    XCTAssertEqual(error as? EmbeddedConverterError, .conversionFailed(reason))
                }
            }
            XCTAssertEqual(live(), 0, "Conversion leaked an owned C string for mode \(mode)")
            XCTAssertEqual(freed(), 1)
            XCTAssertEqual(closed(), mode <= 2 ? 1 : 0)
            XCTAssertEqual(invalid(), 0)
        }
    }
}
