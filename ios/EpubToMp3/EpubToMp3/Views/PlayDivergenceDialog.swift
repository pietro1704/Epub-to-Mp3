import SwiftUI

/// `confirmationDialog` shown when the user taps a play button while
/// the reader is on a different chapter than the audio. Surfaces the
/// canonical three-option chooser (current page / where stopped /
/// beginning) and routes the choice back to `AudioPlayer`'s shared
/// helpers so every play surface behaves identically.
///
/// Usage:
/// ```swift
/// @State private var showingStartChoice = false
/// Button { handlePlayTap() } label: { ... }
/// .playDivergenceDialog(
///     player: player,
///     readerChapterIndex: readerChapterIndex,
///     isPresented: $showingStartChoice
/// )
/// ```
///
/// `handlePlayTap()` should consult
/// `player.playTapDecision(readerChapterIndex:)` and either toggle or
/// flip `showingStartChoice = true`.
struct PlayDivergenceDialog: ViewModifier {
    @ObservedObject var player: AudioPlayer
    let readerChapterIndex: Int
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.confirmationDialog(
            L10n.string("player.divergence.title"),
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            Button(L10n.string("player.divergence.fromCurrentPage")) {
                let defaults = UserDefaults.standard
                player.startFromReaderPage(
                    readerChapterIndex,
                    sentenceId: defaults.string(
                        forKey: AudioPlayer.readerCurrentSentenceIdDefaultsKey
                    ),
                    sentenceOffsetRatio: defaults.object(
                        forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey
                    ) as? Double
                )
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
        readerChapterIndex: Int,
        isPresented: Binding<Bool>
    ) -> some View {
        modifier(
            PlayDivergenceDialog(
                player: player,
                readerChapterIndex: readerChapterIndex,
                isPresented: isPresented
            )
        )
    }
}
