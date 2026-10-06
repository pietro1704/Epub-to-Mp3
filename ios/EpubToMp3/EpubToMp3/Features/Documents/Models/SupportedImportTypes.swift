import Foundation
import UniformTypeIdentifiers

/// Single source of truth for the file types the app can import, shared by
/// every picker (iOS `UIDocumentPickerViewController`, macOS `NSOpenPanel`).
/// Previously this list was duplicated across `ConvertScreenController`,
/// `LibraryScreenController`, `MacLibraryViewController`, and
/// `BookOpenScreenController` — with only 2 formats that was tolerable; with
/// 8 it isn't (the next format would need editing 4 files in lockstep).
///
/// Several of these formats have no Apple-declared public UTI (FB2, CBZ,
/// CBR, MOBI/AZW3). `UTType(filenameExtension:)` still returns a usable
/// (dynamically synthesized) type for an unregistered extension — that's
/// sufficient for picker filtering, so no `UTImportedTypeDeclarations` in
/// Info.plist is required for this to work.
enum SupportedImportTypes {
    static let all: [UTType] = {
        // Apple Books may materialise an EPUB as a directory whose name still
        // ends in `.epub`. Accept folders so the importer can package a valid
        // expanded EPUB before storing it in the library.
        var types: [UTType] = [.epub, .pdf, .folder]
        if let zip = UTType("org.idpf.epub-container") { types.append(zip) }
        for ext in ["fb2", "docx", "cbz", "cbr", "mobi", "azw", "azw3", "prc"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }()
}
