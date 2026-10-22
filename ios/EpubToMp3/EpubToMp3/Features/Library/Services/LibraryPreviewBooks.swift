import Foundation

#if DEBUG
enum LibraryPreviewBooks {
    static func populated(now: Date) -> [BookEntity] {
        [
            BookEntity(
                id: "preview-1",
                title: "Foundation",
                author: "Isaac Asimov",
                bookmark: Data(),
                displayFilename: "foundation.epub",
                addedAt: now.addingTimeInterval(-86400 * 7),
                lastOpenedAt: now.addingTimeInterval(-3600),
                lastChapterIndex: 2,
                lastPositionSeconds: 73,
                coverPNG: nil,
                lastJobId: nil,
                cachedOffline: false
            ),
            BookEntity(
                id: "preview-2",
                title: "Metro 2033",
                author: "Dmitry Glukhovsky",
                bookmark: Data(),
                displayFilename: "metro2033.epub",
                addedAt: now.addingTimeInterval(-86400 * 30),
                lastOpenedAt: now.addingTimeInterval(-86400),
                lastChapterIndex: 12,
                lastPositionSeconds: 0,
                coverPNG: nil,
                lastJobId: "preview-job-id",
                cachedOffline: true
            ),
            BookEntity(
                id: "preview-3",
                title: "O Hobbit",
                author: "J.R.R. Tolkien",
                bookmark: Data(),
                displayFilename: "o_hobbit.epub",
                addedAt: now.addingTimeInterval(-86400 * 2),
                lastOpenedAt: nil,
                lastChapterIndex: nil,
                lastPositionSeconds: nil,
                coverPNG: nil,
                lastJobId: "preview-pending",
                cachedOffline: false
            ),
        ]
    }
}
#endif
