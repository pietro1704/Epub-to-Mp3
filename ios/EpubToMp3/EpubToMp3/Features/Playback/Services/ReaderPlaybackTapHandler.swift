#if os(iOS)
import UIKit

/// Routes an in-app Play tap through the reader's live page anchor.
/// System media commands deliberately bypass this handler because they have
/// no presentation surface for a start-position choice.
@MainActor
enum ReaderPlaybackTapHandler {
    static func handle(player: AudioPlayer, presenting viewController: UIViewController) {
        let defaults = UserDefaults.standard
        guard let chapterIndex = defaults.object(
            forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey
        ) as? Int else {
            player.togglePlayPause()
            return
        }
        let pageRatio = defaults.object(
            forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey
        ) as? Double
        switch player.playTapDecision(
            readerChapterIndex: chapterIndex,
            readerPageRatio: pageRatio
        ) {
        case .pause:
            player.pause()
        case .resume:
            player.resume()
        case .startFromReaderPage:
            player.startFromReaderPage(
                chapterIndex,
                sentenceId: defaults.string(forKey: AudioPlayer.readerCurrentSentenceIdDefaultsKey),
                sentenceOffsetRatio: pageRatio
            )
        case .offerStartChoice:
            presentStartChoice(
                player: player,
                chapterIndex: chapterIndex,
                pageRatio: pageRatio,
                presenting: viewController
            )
        }
    }

    private static func presentStartChoice(
        player: AudioPlayer,
        chapterIndex: Int,
        pageRatio: Double?,
        presenting viewController: UIViewController
    ) {
        guard viewController.presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: L10n.string("player.divergence.title"),
            message: L10n.string("player.divergence.message"),
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(
            title: L10n.string("player.divergence.fromCurrentPage"),
            style: .default
        ) { _ in
            player.startFromReaderPage(
                chapterIndex,
                sentenceId: UserDefaults.standard.string(
                    forKey: AudioPlayer.readerCurrentSentenceIdDefaultsKey
                ),
                sentenceOffsetRatio: pageRatio
            )
        })
        alert.addAction(UIAlertAction(
            title: L10n.string("player.divergence.fromWhereStopped"),
            style: .default
        ) { _ in player.resume() })
        alert.addAction(UIAlertAction(
            title: L10n.string("player.divergence.fromBeginning"),
            style: .destructive
        ) { _ in player.startFromBeginning() })
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = viewController.view
            popover.sourceRect = viewController.view.bounds
        }
        viewController.present(alert, animated: true)
    }
}
#endif
