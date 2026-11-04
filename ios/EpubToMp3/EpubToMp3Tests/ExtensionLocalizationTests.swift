import XCTest
@testable import EpubToMp3

final class ExtensionLocalizationTests: XCTestCase {
    private let languages = ["en", "pt-BR", "es"]

    private func localization(_ language: String, in bundle: Bundle = .main) throws -> Bundle {
        let path = try XCTUnwrap(bundle.path(forResource: language, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    func testWidgetLabelsAndFormattedValuesInEveryLanguage() throws {
        let expected = [
            ["Now Playing", "42% complete", "Chapter 5 of 18", "5m remaining · book 2h", "Foundation · 5m remaining"],
            ["Tocando Agora", "42% concluído", "Capítulo 5 de 18", "5m restantes · livro 2h", "Foundation · 5m restantes"],
            ["Reproduciendo Ahora", "42% completado", "Capítulo 5 de 18", "5m restantes · libro 2h", "Foundation · 5m restantes"]
        ]
        for (language, values) in zip(languages, expected) {
            let bundle = try localization(language)
            XCTAssertEqual(L10n.string("widget.nowPlaying", bundle: bundle), values[0], language)
            XCTAssertEqual(L10n.string("widget.percentComplete", 42, bundle: bundle), values[1], language)
            XCTAssertEqual(L10n.string("player.chapterOf", 5, 18, bundle: bundle), values[2], language)
            XCTAssertEqual(L10n.string("widget.remainingTimes", "5m", "2h", bundle: bundle), values[3], language)
            XCTAssertEqual(L10n.string("widget.titleRemaining", "Foundation", "5m", bundle: bundle), values[4], language)
        }
    }

    func testShareConfirmationSuccessFailureAndEmptyInputInEveryLanguage() throws {
        let expected = [
            ["1 book imported to EpubToMp3", "3 books imported to EpubToMp3", "Import failed: Disk full",
             "Nothing to import (no EPUB or PDF attached)"],
            ["1 livro importado para o EpubToMp3", "3 livros importados para o EpubToMp3",
             "Falha na importação: Disk full", "Nada para importar (nenhum EPUB ou PDF anexado)"],
            ["1 libro importado a EpubToMp3", "3 libros importados a EpubToMp3", "Error al importar: Disk full",
             "Nada que importar (ningún EPUB o PDF adjunto)"]
        ]
        for (language, values) in zip(languages, expected) {
            let bundle = try localization(language)
            XCTAssertEqual(ShareImportPresentation.summary(imported: 1, firstError: nil, bundle: bundle), values[0])
            // Preserve partial-success precedence over an attachment error.
            XCTAssertEqual(ShareImportPresentation.summary(imported: 3, firstError: "Disk full", bundle: bundle), values[1])
            XCTAssertEqual(ShareImportPresentation.summary(imported: 0, firstError: "Disk full", bundle: bundle), values[2])
            XCTAssertEqual(ShareImportPresentation.summary(imported: 0, firstError: nil, bundle: bundle), values[3])
        }
    }

    func testUnsupportedAttachmentRetainsItsDiagnosticType() throws {
        let expected = ["Unsupported attachment payload (Optional<Any>).",
                        "Conteúdo do anexo não suportado (Optional<Any>).",
                        "Contenido del adjunto no compatible (Optional<Any>)."]
        for (language, value) in zip(languages, expected) {
            XCTAssertEqual(L10n.string("share.unsupportedAttachment", "Optional<Any>",
                                       bundle: try localization(language)), value)
        }
    }

    func testContinueReadingLocalizesOlderPayloadsAndPreservesHostLabel() {
        var entry = ContinueReadingEntry(date: Date(), title: "Foundation", author: nil,
                                        chapterIndex: 4, totalChapters: 18, coverData: nil, bookId: "book-1")
        XCTAssertEqual(entry.chapterLabel, L10n.string("player.chapterOf", 5, 18))
        entry.localizedChapterLabel = "Capítulo cinco"
        XCTAssertEqual(entry.chapterLabel, "Capítulo cinco")
        entry.localizedChapterLabel = ""
        XCTAssertEqual(entry.chapterLabel, L10n.string("player.chapterOf", 5, 18))
        let unknownTotal = ContinueReadingEntry(date: Date(), title: "Foundation", author: nil,
                                               chapterIndex: 4, totalChapters: nil, coverData: nil, bookId: "book-1")
        XCTAssertEqual(unknownTotal.chapterLabel, L10n.string("player.chapter", 5))
        XCTAssertNil(ContinueReadingEntry.empty.chapterLabel)
    }

    func testUnknownLocalizationKeyRemainsIdentifiable() throws {
        for language in languages {
            XCTAssertEqual(L10n.string("missing.extension.key", bundle: try localization(language)), "missing.extension.key")
        }
    }

    #if os(iOS)
    func testEmbeddedExtensionsContainTheirOwnLocalizedResources() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        for name in ["EpubToMp3Widget", "EpubToMp3ShareExtension"] {
            let bundle = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("\(name).appex")))
            for language in languages {
                let extensionLocale = try localization(language, in: bundle)
                let appLocale = try localization(language)
                let keys = name == "EpubToMp3Widget"
                    ? ["widget.nowPlaying", "widget.remainingTimes", "player.chapterOf", "widget.playPauseIntent",
                       "widget.skipForwardIntentDescription", "widget.lockScreenDescription"]
                    : ["share.importing", "share.importedOne", "share.importedMany", "share.importFailed",
                       "share.nothingToImport", "share.unsupportedAttachment"]
                for key in keys {
                    let value = extensionLocale.localizedString(forKey: key, value: key, table: nil)
                    XCTAssertNotEqual(value, key, "\(name): \(language): \(key)")
                    XCTAssertEqual(value, appLocale.localizedString(forKey: key, value: key, table: nil))
                }
            }
        }
    }
    #endif
}
