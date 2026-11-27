import XCTest
@testable import EpubToMp3

final class ResumeChoiceCopyTests: XCTestCase {
    private func copy(readerPage: Int?, audioPage: Int?, audio: Bool = true) -> ResumeChoiceCopy {
        ResumeChoiceCopy(
            reader: .init(chapterIndex: 2, page: readerPage),
            audio: audio ? .init(chapterIndex: 4, page: audioPage, seconds: 754) : nil,
            localize: { key, arguments in
                String(format: Self.portuguese[key] ?? key, arguments: arguments)
            }
        )
    }

    private static let portuguese: [String: String] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3/Resources/pt-BR.lproj/Localizable.strings")
        return NSDictionary(contentsOf: url) as? [String: String] ?? [:]
    }()

    func testNamesBothPlacesWithTheApprovedWording() {
        let value = copy(readerPage: 12, audioPage: 40)
        XCTAssertEqual(value.message, "Você está na página 12 (cap. 3). O áudio parou na página 40 (cap. 5, 12:34).")
        XCTAssertEqual(value.listenTitle, "Ouvir desta página (p. 12)")
        XCTAssertEqual(value.returnTitle, "Voltar ao áudio (p. 40, cap. 5)")
    }

    func testOmitsAPageThatIsNotKnownInsteadOfGuessingIt() {
        let value = copy(readerPage: nil, audioPage: nil)
        XCTAssertEqual(value.message, "Você está no cap. 3. O áudio parou no cap. 5 (12:34).")
        XCTAssertEqual(value.listenTitle, "Ouvir desta página")
        XCTAssertEqual(value.returnTitle, "Voltar ao áudio (cap. 5)")
    }

    func testKeepsTheReaderPlaceWhenTheAudioPlaceIsUnknown() {
        let value = copy(readerPage: 12, audioPage: nil, audio: false)
        XCTAssertEqual(value.message, "Você está na página 12 (cap. 3).")
        XCTAssertEqual(value.listenTitle, "Ouvir desta página (p. 12)")
        XCTAssertEqual(value.returnTitle, "Voltar ao áudio")
    }

    func testEveryLocaleDefinesTheSameDivergenceKeys() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3/Resources")
        var keys: [String: Set<String>] = [:]
        for locale in try FileManager.default.contentsOfDirectory(atPath: resources.path) where locale.hasSuffix(".lproj") {
            let url = resources.appendingPathComponent(locale).appendingPathComponent("Localizable.strings")
            guard let table = NSDictionary(contentsOf: url) as? [String: String] else { continue }
            keys[locale] = Set(table.keys.filter { $0.hasPrefix("player.divergence.") })
        }
        let expected = try XCTUnwrap(keys["pt-BR.lproj"])
        XCTAssertEqual(expected.count, 10)
        for (locale, value) in keys { XCTAssertEqual(value, expected, locale) }
    }
}
