# Reader interaction components integration notes

The reusable interaction layer is intentionally not wired into `ReaderView.swift`, `InstantReaderView.swift`, or `PlayerReaderView.swift` in this change. The existing hosts have different pagination/scrolling and UIKit/TextKit ownership, and broad edits would risk changing selection and follow behavior.

## Minimal host edits

1. In each reader host, keep its existing long-press/double-tap selection callback and resolve two values from that selection:
   - the tapped/selected `SentenceSpan`;
   - the first `SentenceSpan` in the selected paragraph.
2. Store those values in host state and place `ReaderSelectionActionFloater` in the existing reader `ZStack` overlay. Supply a `ReaderSelectionActionFloaterModel` whose callbacks call the host's existing play-from-anchor route:
   - sentence: play the selected span;
   - paragraph: play `paragraphFirstSentence`.
   The floater installs no gestures and does not clear selection, so UIKit/TextKit selection remains intact.
3. Add host-owned `ReaderFollowState`. On a user page/chapter/scroll change call `manualNavigation(at: Date())`; use `shouldPresentFollowButton(at:)` to drive `ReaderFollowButton(isVisible:action:)`. The button action calls `followAudio()`, then the host immediately applies its saved audio anchor (chapter, page/scroll, and sentence).
4. In the host's audio-position observer, use `shouldFollowAudio(at:)` to resume automatic positioning after the five-second cooldown. An explicit button tap resumes immediately and clears the button state.

## Contracts

- Portuguese labels are exactly `Tocar desta frase`, `Tocar deste parágrafo`, and `Acompanhar`; other locales use the same localization keys.
- Stable accessibility identifiers are `reader.selection.playSentence`, `reader.selection.playParagraph`, `reader.selectionFloater`, and `reader.followButton`.
- `ReaderSelectionActionFloaterModel` is view-independent and callback-injected, so a UIKit host can use it without importing SwiftUI gesture logic.
- `ReaderFollowState.cooldownDuration` is exactly five seconds; presentation is active strictly before the deadline.
