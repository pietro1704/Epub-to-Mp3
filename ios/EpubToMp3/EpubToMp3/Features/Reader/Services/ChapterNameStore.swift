import Foundation

/// The reader's chapter name overrides, one file per book, local to the device. Rust owns the
/// file format and validation. Keys are the parsed (1-based) chapter indexes.
struct ChapterNameStore: Sendable {
    static let shared = ChapterNameStore(directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("chapter-names", isDirectory: true))

    let directory: URL

    /// A book that was never renamed has no file and never loads Rust.
    func names(bookID: String) -> [Int: String] {
        let file = fileURL(bookID)
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return (try? ConverterFFIAdapter().chapterNames(at: file, index: nil, name: nil)) ?? [:]
    }

    /// A nil or blank `name` restores the automatic name.
    @discardableResult
    func set(bookID: String, chapter: Int, name: String?) throws -> [Int: String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try ConverterFFIAdapter().chapterNames(at: fileURL(bookID), index: String(chapter), name: name)
    }

    private func fileURL(_ bookID: String) -> URL {
        let safe = bookID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? bookID
        return directory.appendingPathComponent("\(safe).json")
    }
}
