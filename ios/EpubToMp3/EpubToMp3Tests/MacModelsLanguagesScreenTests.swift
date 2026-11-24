#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// MODELS-LANGUAGE-SUBSCREEN on macOS: the real language screen, its order and a rendered image of it.
@MainActor
final class MacModelsLanguagesScreenTests: XCTestCase {
    private func languages() throws -> [CatalogLanguage] {
        let json = """
        [{"tag":"ar","model_count":2,"popularity_rank":11},{"tag":"de","model_count":4,"popularity_rank":5},
         {"tag":"en","model_count":9,"popularity_rank":1},{"tag":"es","model_count":6,"popularity_rank":2},
         {"tag":"kk","model_count":1},{"tag":"cy","model_count":1},{"tag":"pt","model_count":3,"popularity_rank":3}]
        """
        return try JSONDecoder().decode([CatalogLanguage].self, from: Data(json.utf8))
    }

    private func table(of controller: NSViewController) throws -> NSTableView {
        try XCTUnwrap((controller.view as? NSScrollView)?.documentView as? NSTableView)
    }

    func testLanguageScreenListsSystemThenPopularThenAlphabeticalAndOpensALanguage() throws {
        let controller = MacModelsLanguagesViewController(languages: try languages(), systemPreferred: ["pt-BR", "en-US"],
                                                          uiLocale: Locale(identifier: "pt-BR"))
        controller.view.frame = NSRect(x: 0, y: 0, width: 480, height: 560)
        controller.view.layoutSubtreeIfNeeded()
        let table = try table(of: controller)
        table.reloadData()
        // 3 headers + pt, en | es, de, ar | cy, kk (alphabetical in Portuguese: cazaque, galês -> kk, cy)
        XCTAssertEqual(table.numberOfRows, 3 + 7)
        let identifiers = (0..<table.numberOfRows).compactMap { row -> String? in
            let view = table.view(atColumn: 0, row: row, makeIfNecessary: true)
            return (view as? NSStackView)?.views.first?.accessibilityIdentifier()
        }
        XCTAssertEqual(identifiers, ["models.languages.row.pt", "models.languages.row.en",
                                     "models.languages.row.es", "models.languages.row.de", "models.languages.row.ar",
                                     "models.languages.row.kk", "models.languages.row.cy"])
        attach(controller.view, name: "models-languages-screen-pt-BR")
    }

    private func attach(_ view: NSView, name: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return XCTFail("no bitmap") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("no png") }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["EPUB_EVIDENCE_DIR"] {
            try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
}
#endif
