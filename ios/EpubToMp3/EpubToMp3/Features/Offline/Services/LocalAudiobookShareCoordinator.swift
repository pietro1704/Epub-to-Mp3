#if os(iOS)
import UIKit

/// Presents a standard share sheet for the finished portion of an embedded
/// audiobook. The manifest makes a partial export explicit to the recipient.
@MainActor
enum LocalAudiobookShareCoordinator {
    static func exportAndPresent(bookID: String, from presenter: UIViewController) {
        Task {
            do {
                guard let manifest = try await LocalAudioArtifactStore.shared.manifest(bookID: bookID) else {
                    throw LocalAudiobookArchiveExporter.ExportError.noAudio
                }
                var chapters: [LocalAudiobookArchiveExporter.Chapter] = []
                for artifact in manifest.chapters {
                    let fileURL = try await LocalAudioArtifactStore.shared.canonicalURL(
                        bookID: bookID,
                        chapterIndex: artifact.index
                    )
                    chapters.append(.init(
                        index: artifact.index,
                        title: artifact.title,
                        fileURL: fileURL,
                        availability: LocalAudiobookArchiveExporter.Availability(
                            rawValue: artifact.state.rawValue
                        ) ?? .missing,
                        lastError: artifact.lastError
                    ))
                }
                let exportsDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("EpubToMp3AudioExports", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                let archiveURL = try LocalAudiobookArchiveExporter.export(
                    bookID: manifest.bookID,
                    bookTitle: manifest.bookTitle,
                    author: manifest.author,
                    chapters: chapters,
                    destinationDirectory: exportsDirectory
                )
                let activity = UIActivityViewController(activityItems: [archiveURL], applicationActivities: nil)
                if let popover = activity.popoverPresentationController {
                    popover.sourceView = presenter.view
                    popover.sourceRect = presenter.view.bounds
                }
                activity.completionWithItemsHandler = { _, _, _, _ in
                    try? FileManager.default.removeItem(at: exportsDirectory)
                }
                presenter.present(activity, animated: true)
            } catch {
                let alert = UIAlertController(
                    title: L10n.string("player.exportAudio"),
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
                presenter.present(alert, animated: true)
            }
        }
    }
}
#endif
