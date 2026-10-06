#if os(iOS)
@preconcurrency import CarPlay
import UIKit

/// CarPlay owns presentation only. Playback remains in the application's
/// single AudioPlayer, which already publishes Now Playing metadata and
/// remote commands for Lock Screen, Control Center, headphones, and AirPlay.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private weak var interfaceController: CPInterfaceController?

    nonisolated func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        Task { @MainActor [weak self] in
            self?.connect(interfaceController)
        }
    }

    nonisolated func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        Task { @MainActor [weak self] in
            self?.disconnect(interfaceController)
        }
    }

    private func connect(_ interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let nowPlaying = CPNowPlayingTemplate.shared
        let library = makeLibraryTemplate()
        let tabs = CPTabBarTemplate(templates: [library, nowPlaying])
        interfaceController.setRootTemplate(tabs, animated: false) { _, _ in }
    }

    private func disconnect(_ interfaceController: CPInterfaceController) {
        if self.interfaceController === interfaceController {
            self.interfaceController = nil
        }
    }

    private func makeLibraryTemplate() -> CPListTemplate {
        let app = UIApplication.shared.delegate as? EpubToMp3App
        let items = (app?.library.books ?? []).prefix(100).map { book in
            let item = CPListItem(
                text: book.resolvedTitle,
                detailText: book.author ?? "—"
            )
            item.handler = { [weak app] _, completion in
                guard let app,
                      let snapshot = app.player.snapshot,
                      snapshot.bookTitle == book.resolvedTitle || snapshot.jobId == book.lastJobId else {
                    completion()
                    return
                }
                app.player.play(snapshot: snapshot)
                completion()
            }
            return item
        }
        let section = CPListSection(items: Array(items))
        return CPListTemplate(title: L10n.string("library.title"), sections: [section])
    }
}
#endif
