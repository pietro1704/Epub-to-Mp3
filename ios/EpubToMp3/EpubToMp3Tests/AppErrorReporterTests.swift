import Foundation
import XCTest
@testable import EpubToMp3

final class AppErrorReporterTests: XCTestCase {
    func testAlertMessageAlsoWritesErrorIdentityAndCauseToTerminal() throws {
        let pipe = Pipe()
        let error = NSError(domain: "FixtureProvider", code: 17,
                            userInfo: [NSLocalizedDescriptionKey: "Primary voice failed"])
        let message = AppErrorReporter.message(error, context: "Reader listening",
                                              destination: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        let diagnostic = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(message, "Primary voice failed")
        XCTAssertEqual(diagnostic, "[App][Error] Reader listening [FixtureProvider:17]: Primary voice failed\n")
    }

    func testStringFailureRetainsLocalizedAlertAndPrefixesEveryDiagnosticLine() throws {
        let pipe = Pipe()
        let message = "Voz indisponível\nProvider timeout"
        XCTAssertEqual(AppErrorReporter.message(message, context: "Conversion",
                                               destination: pipe.fileHandleForWriting), message)
        try pipe.fileHandleForWriting.close()
        let diagnostic = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(diagnostic, "[App][Error] Conversion: Voz indisponível\n[App][Error] Conversion: Provider timeout\n")
    }
}
