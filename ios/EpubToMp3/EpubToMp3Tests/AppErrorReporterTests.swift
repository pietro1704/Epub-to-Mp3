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
    func testEmbeddedDiagnosticIsRetainedWhileAlertUsesLocalizedMessage() throws {
        let pipe = Pipe()
        let error = EmbeddedConverterError.conversionFailed("private runtime diagnostic")
        let text = AppErrorReporter.message(error, context: "Conversion", destination: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        let diagnostic = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(text, L10n.string("error.conversionFailed"))
        XCTAssertFalse(text.contains("private runtime diagnostic"))
        XCTAssertTrue(diagnostic.contains("private runtime diagnostic"))
    }

    func testMismatchEnvelopePreservesLanguageAndModelWithoutParsingEnglish() throws {
        let payload = "[[tts_language_mismatch_v1]]{\"language\":\"en-US\",\"model_id\":\"pt_BR-faber-medium\"}[[/tts_language_mismatch_v1]]"
        let error = EmbeddedConverterError.conversionFailed("wrapped system speech error: " + payload)
        let mismatch = try XCTUnwrap(TtsLanguageMismatch.decode(error))
        XCTAssertEqual(mismatch.language, "en-US")
        XCTAssertEqual(mismatch.modelID, "pt_BR-faber-medium")
        XCTAssertEqual(error.errorDescription, L10n.string("error.modelLanguage"))
        XCTAssertNil(TtsLanguageMismatch.decode(EmbeddedConverterError.conversionFailed("unrelated failure")))
        XCTAssertNil(TtsLanguageMismatch.decode(EmbeddedConverterError.conversionFailed("[[tts_language_mismatch_v1]]{}[[/tts_language_mismatch_v1]]")))
        XCTAssertNil(TtsLanguageMismatch.decode(CancellationError()))
    }

}
