import SwiftUI

/// Immutable snapshot of where the user is reading at the moment
/// divergence was detected. Captured at `handlePlayTap()` time and
/// handed to the dialog so the "From the current page" choice
/// references the page the user was on **when they pressed Play** —
/// not whatever page they happen to be on 250 ms later (the dialog
/// animation gives them time to keep swiping).
struct PlayDivergenceAnchor: Equatable {
    let readerChapterIndex: Int
    let pageRatio: Double?
    let sentenceId: String?

    /// Reads the three reader-position channels from `UserDefaults` in
    /// one shot. Call this at the moment the divergence is detected,
    /// not at the moment a button is tapped.
    @MainActor
    static func capture(readerChapterIndex: Int) -> PlayDivergenceAnchor {
        let defaults = UserDefaults.standard
        return PlayDivergenceAnchor(
            readerChapterIndex: readerChapterIndex,
            pageRatio: defaults.object(
                forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey
            ) as? Double,
            sentenceId: defaults.string(
                forKey: AudioPlayer.readerCurrentSentenceIdDefaultsKey
            )
        )
    }
}

/// `confirmationDialog` shown when the user taps a play button while
/// the reader is on a different chapter than the audio. Surfaces the
/// canonical three-option chooser (current page / where stopped /
/// beginning) and routes the choice back to `AudioPlayer`'s shared
/// helpers so every play surface behaves identically.
///
/// Usage:
/// ```swift
/// @State private var pendingAnchor: PlayDivergenceAnchor?
/// Button { handlePlayTap() } label: { ... }
/// .playDivergenceDialog(player: player, anchor: $pendingAnchor)
///
/// private func handlePlayTap() {
///     switch player.playTapDecision(readerChapterIndex: readerChapterIndex) {
///     case .pause, .resume: player.togglePlayPause()
///     case .offerStartChoice:
///         pendingAnchor = .capture(readerChapterIndex: readerChapterIndex)
///     }
/// }
/// ```
struct PlayDivergenceDialog: ViewModifier {
    @ObservedObject var player: AudioPlayer
    @Binding var anchor: PlayDivergenceAnchor?

    private var isPresented: Binding<Bool> {
        Binding(
            get: { anchor != nil },
            set: { if !$0 { anchor = nil } }
        )
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            L10n.string("player.divergence.title"),
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button(L10n.string("player.divergence.fromCurrentPage")) {
                if let anchor {
                    player.startFromReaderPage(
                        anchor.readerChapterIndex,
                        sentenceId: anchor.sentenceId,
                        sentenceOffsetRatio: anchor.pageRatio
                    )
                }
            }
            Button(L10n.string("player.divergence.fromWhereStopped")) {
                player.resume()
            }
            Button(L10n.string("player.divergence.fromBeginning")) {
                player.startFromBeginning()
            }
            Button(L10n.string("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("player.divergence.message"))
        }
    }
}

extension View {
    func playDivergenceDialog(
        player: AudioPlayer,
        anchor: Binding<PlayDivergenceAnchor?>
    ) -> some View {
        modifier(PlayDivergenceDialog(player: player, anchor: anchor))
    }
}
