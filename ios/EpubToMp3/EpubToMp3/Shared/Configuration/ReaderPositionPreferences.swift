import Foundation

struct ReaderPositionPreferences {
    let defaults: UserDefaults

    // MARK: Reading position persistence

    func savedChapterIndex(for bookId: String) -> Int {
        defaults.integer(forKey: "readPos_ch_\(bookId)")
    }

    func saveChapterIndex(_ index: Int, for bookId: String) {
        defaults.set(index, forKey: "readPos_ch_\(bookId)")
    }

    func savedPageIndex(for bookId: String) -> Int {
        defaults.integer(forKey: "readPos_pg_\(bookId)")
    }

    func savePageIndex(_ index: Int, for bookId: String) {
        defaults.set(index, forKey: "readPos_pg_\(bookId)")
    }

}
