// PiperBridgeTests.swift
//
// Slice 1b (stub-only): pins the contract that PiperBridge.synthesize
// always throws .notImplemented for now, regardless of language. When
// the bring-up slices land (onnxruntime / espeak-ng / lame) and the
// stub is replaced, these tests get updated -- but the engine-gate
// contract (unsupported languages still throw) survives.

#if os(iOS) || targetEnvironment(simulator)

import XCTest
@testable import EpubToMp3

final class PiperBridgeTests: XCTestCase {

    // MARK: - .notImplemented contract (every supported language throws today)

    func testSynthesizeSupportedLanguagesThrowsNotImplemented() async throws {
        let bridge = PiperBridge()
        for tag in PiperBridge.supportedLanguages {
            do {
                _ = try await bridge.synthesize(text: "hello", language: tag)
                XCTFail("expected .notImplemented for supported language \(tag)")
            } catch let error as PiperBridgeError {
                switch error {
                case .notImplemented:
                    continue  // expected
                default:
                    XCTFail("supported language \(tag) threw \(error) instead of .notImplemented")
                }
            } catch {
                XCTFail("unexpected error type for \(tag): \(error)")
            }
        }
    }

    func testSynthesizePtBRThrowsNotImplemented() async {
        let bridge = PiperBridge()
        do {
            _ = try await bridge.synthesize(text: "olá", language: "pt-BR")
            XCTFail("expected .notImplemented for pt-BR")
        } catch let error as PiperBridgeError {
            guard case .notImplemented = error else {
                return XCTFail("expected .notImplemented, got \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testSynthesizeEnUSThrowsNotImplemented() async {
        let bridge = PiperBridge()
        do {
            _ = try await bridge.synthesize(text: "hello", language: "en-US")
            XCTFail("expected .notImplemented for en-US")
        } catch let error as PiperBridgeError {
            guard case .notImplemented = error else {
                return XCTFail("expected .notImplemented, got \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - Language gate (unsupported tags fail before reaching the stub)

    func testSynthesizeUnsupportedLanguageThrowsUnsupported() async {
        let bridge = PiperBridge()
        do {
            _ = try await bridge.synthesize(text: "hallo", language: "de-DE")
            XCTFail("expected .unsupportedLanguage")
        } catch let error as PiperBridgeError {
            guard case .unsupportedLanguage(let tag) = error else {
                return XCTFail("expected .unsupportedLanguage, got \(error)")
            }
            XCTAssertEqual(tag, "de-DE")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testSynthesizeEmptyLanguageThrowsUnsupported() async {
        let bridge = PiperBridge()
        do {
            _ = try await bridge.synthesize(text: "hi", language: "")
            XCTFail("expected .unsupportedLanguage")
        } catch let error as PiperBridgeError {
            guard case .unsupportedLanguage = error else {
                return XCTFail("expected .unsupportedLanguage, got \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - Language normalisation

    func testNormaliseLanguageCanonicalisesUnderscoreForm() {
        XCTAssertEqual(PiperBridge.normaliseLanguage("pt_BR"), "pt-BR")
        XCTAssertEqual(PiperBridge.normaliseLanguage("en_US"), "en-US")
    }

    func testNormaliseLanguageCanonicalisesCase() {
        XCTAssertEqual(PiperBridge.normaliseLanguage("pt-br"), "pt-BR")
        XCTAssertEqual(PiperBridge.normaliseLanguage("EN-us"), "en-US")
    }

    func testNormaliseLanguageDefaultsBarePrimary() {
        XCTAssertEqual(PiperBridge.normaliseLanguage("pt"), "pt-BR")
        XCTAssertEqual(PiperBridge.normaliseLanguage("en"), "en-US")
    }

    func testNormaliseLanguagePassesThroughUnknown() {
        XCTAssertEqual(PiperBridge.normaliseLanguage("de"), "de")
        XCTAssertEqual(PiperBridge.normaliseLanguage("de-DE"), "de-DE")
    }

    func testNormalisationDoesNotMaskUnsupportedDeRegion() async {
        // Even with valid casing, "de-DE" is not in PiperBridgeLanguage
        // and must surface as .unsupportedLanguage.
        let bridge = PiperBridge()
        do {
            _ = try await bridge.synthesize(text: "Hallo", language: "de_DE")
            XCTFail("expected .unsupportedLanguage")
        } catch let error as PiperBridgeError {
            guard case .unsupportedLanguage = error else {
                return XCTFail("expected .unsupportedLanguage, got \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - Static surface

    func testSupportedLanguagesMatchEnum() {
        let fromEnum = PiperBridgeLanguage.allCases.map { $0.rawValue }
        XCTAssertEqual(PiperBridge.supportedLanguages, fromEnum)
        XCTAssertTrue(PiperBridge.supportedLanguages.contains("pt-BR"))
        XCTAssertTrue(PiperBridge.supportedLanguages.contains("en-US"))
    }

    func testNotImplementedErrorDescriptionMentionsBringUpDoc() {
        let error = PiperBridgeError.notImplemented
        let description = error.errorDescription ?? ""
        XCTAssertTrue(
            description.contains("ios/PIPER-EMBED.md"),
            "errorDescription should point operators at the bring-up doc; "
                + "got: \(description)"
        )
        XCTAssertTrue(description.contains("onnxruntime"))
        XCTAssertTrue(description.contains("espeak-ng"))
        XCTAssertTrue(description.contains("lame"))
    }
}

#endif  // os(iOS) || targetEnvironment(simulator)
