import Foundation
#if canImport(UIKit)
import UIKit
typealias ReaderCatalogFont = UIFont
#else
import AppKit
typealias ReaderCatalogFont = NSFont
#endif

/// Uses public OS fonts only. Resolution never requests a font download.
@MainActor
enum ReaderFontCatalog {
    static var availableFamilies: Set<String> {
        #if canImport(UIKit)
        return Set(UIFont.familyNames)
        #else
        return Set(NSFontManager.shared.availableFontFamilies)
        #endif
    }

    static func choices(retaining requested: ReaderFontFamily) -> [ReaderFontFamily] {
        let families = availableFamilies
        return [.original] + ReaderFontFamily.allCases.filter {
            $0 != .original && ($0.isAvailable(in: families) || $0 == requested)
        }
    }

    static func title(for family: ReaderFontFamily) -> String {
        family.isAvailable(in: availableFamilies) ? family.displayName
            : family.displayName + " — " + L10n.string("font.unavailable")
    }

    static func font(for family: ReaderFontFamily, size: CGFloat) -> ReaderCatalogFont {
        if let name = family.namedFamily, availableFamilies.contains(name) {
            #if canImport(UIKit)
            let names = UIFont.fontNames(forFamilyName: name).sorted()
            let regular = names.first { $0.hasSuffix("Regular") || $0.hasSuffix("Roman") || $0.hasSuffix("Book") }
            if let font = UIFont(name: regular ?? names.first ?? name, size: size) { return font }
            #else
            if let font = NSFont(name: name, size: size) { return font }
            #endif
        }
        let system = ReaderCatalogFont.systemFont(ofSize: size)
        let descriptor = system.fontDescriptor.withDesign(family == .sanFrancisco ? .default : .serif)
            ?? system.fontDescriptor
        #if canImport(UIKit)
        return UIFont(descriptor: descriptor, size: size)
        #else
        return NSFont(descriptor: descriptor, size: size) ?? system
        #endif
    }

    #if os(macOS)
    static func configure(_ popup: NSPopUpButton, selected: ReaderFontFamily) {
        popup.removeAllItems()
        let families = availableFamilies
        for family in choices(retaining: selected) {
            popup.addItem(withTitle: title(for: family))
            popup.lastItem?.representedObject = family.rawValue
            popup.lastItem?.isEnabled = family.isAvailable(in: families)
            if family != .original {
                popup.lastItem?.attributedTitle = NSAttributedString(string: title(for: family),
                    attributes: [.font: font(for: family, size: 15)])
            }
            if family == selected { popup.select(popup.lastItem) }
        }
        popup.autoenablesItems = false
    }
    #endif
}
