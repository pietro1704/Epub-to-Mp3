#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// A11Y-01/02 on macOS: the contents list speaks localized chapter names and nesting, and secondary text
/// stays readable (WCAG AA 4.5:1) in both appearances.
@MainActor
final class MacReaderAccessibilityTests: XCTestCase {
    private func chapter(_ index: Int, _ name: String) -> EbookFulltext.Chapter {
        .init(index: index, name: name, text: "Text \(index)", html: nil, css: nil, charCount: 6, segments: nil)
    }

    func testContentsListSpeaksItsNameEachChapterTitleAndTheNestingLevel() throws {
        let harness = try NativeReaderTestHarness(chapters: [])
        harness.installTeardown(in: self)
        harness.document.fulltext = EbookFulltext(
            jobId: "a11y", bookTitle: nil, bookAuthor: nil,
            chapters: [chapter(1, "Prologue"), chapter(2, "The Shadow")],
            toc: [.init(title: "Part One", level: 1, chapterIndex: nil, children: [
                .init(title: "Prologue", level: 2, chapterIndex: 1, children: []),
                .init(title: "", level: 2, chapterIndex: 2, children: []),
            ])])
        let contents = MacReaderContentsPresentation(document: harness.document, composition: harness.composition,
                                                     persistProgress: {}, showChapter: { _ in })
        let table = harness.composition.chaptersTable
        XCTAssertEqual(table.accessibilityLabel(), L10n.string("reader.contents"), "The list has a spoken name")
        XCTAssertEqual(contents.numberOfRows(in: table), 3)
        func spoken(_ row: Int) -> String? { (contents.tableView(table, viewFor: nil, row: row) as? NSTableCellView)?.accessibilityLabel() }
        XCTAssertEqual(spoken(0), "Part One")
        XCTAssertEqual(spoken(1), "Prologue", "Indentation spaces are not part of the spoken name")
        XCTAssertEqual(spoken(2), L10n.string("toc.untitledChapter"), "An empty title speaks the localized placeholder")
        XCTAssertEqual(contents.tableView(table, rowViewForRow: 0)?.accessibilityDisclosureLevel(), 0)
        XCTAssertEqual(contents.tableView(table, rowViewForRow: 1)?.accessibilityDisclosureLevel(), 1)
    }

    func testTheContentsLabelIsLocalizedInEveryShippedLanguage() {
        for (language, expected) in [("en", "Contents"), ("pt-BR", "Sumário"), ("es", "Contenido")] {
            let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
            XCTAssertEqual(bundle?.localizedString(forKey: "reader.contents", value: nil, table: nil), expected, language)
        }
    }

    // MARK: contrast

    private func luminance(_ color: NSColor) -> Double {
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let c = color.usingColorSpace(.sRGB)!
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }

    private func flattened(_ color: NSColor, over background: NSColor) -> NSColor {
        let f = color.usingColorSpace(.sRGB)!, b = background.usingColorSpace(.sRGB)!, a = f.alphaComponent
        return NSColor(srgbRed: f.redComponent * a + b.redComponent * (1 - a),
                       green: f.greenComponent * a + b.greenComponent * (1 - a),
                       blue: f.blueComponent * a + b.blueComponent * (1 - a), alpha: 1)
    }

    private func contrast(_ foreground: NSColor, on background: NSColor) -> Double {
        let backdrop = flattened(background, over: .black)
        let l1 = luminance(flattened(foreground, over: backdrop)), l2 = luminance(backdrop)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    func testSecondaryTextMeetsAACContrastOnEveryBackgroundInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                for (label, background) in [("window", NSColor.windowBackgroundColor), ("list", .textBackgroundColor),
                                            ("header", NSColor(white: name == .aqua ? 0.92 : 0.2, alpha: 1))] {
                    let ratio = contrast(.readableSecondaryLabel, on: background)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name.rawValue) on \(label): \(ratio)")
                }
            }
        }
        // The system color it replaces fails in the light appearance (documents why the helper exists).
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            XCTAssertLessThan(contrast(.secondaryLabelColor, on: .windowBackgroundColor), 4.5)
        }
    }
}
#endif
