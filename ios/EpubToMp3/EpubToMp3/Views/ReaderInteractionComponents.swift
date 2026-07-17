import SwiftUI

/// A small action bar that floats above a host's selected text. It does not
/// install gestures or clear selection, so long-press/double-tap selection can
/// remain owned by UIKit/TextKit or by the hosting reader view.
struct ReaderSelectionActionFloater: View {
    let model: ReaderSelectionActionFloaterModel

    var body: some View {
        Group {
            if model.isPresented {
                HStack(spacing: 8) {
                    actionButton(.playFromHere)
                    actionButton(.playChapterStart)
                    actionButton(.sentence)
                    actionButton(.paragraph)
                }
                .padding(8)
                .background(.regularMaterial, in: Capsule())
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("reader.selectionFloater")
            }
        }
    }

    private func actionButton(_ action: ReaderSelectionAction) -> some View {
        Button {
            model.perform(action)
        } label: {
            Text(localized: action.titleKey)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier(action.accessibilityIdentifier)
        .accessibilityLabel(Text(localized: action.titleKey))
    }
}

/// Host-driven follow affordance. Visibility belongs to the host so paginated,
/// scrolling, and UIKit-backed readers can decide when their anchor is stale.
struct ReaderFollowButton: View {
    static let titleKey = "reader.follow"
    static let accessibilityIdentifier = "reader.followButton"

    let isVisible: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isVisible {
                Button(action: action) {
                    Label {
                        Text(localized: Self.titleKey)
                    } icon: {
                        Image(systemName: "arrow.down.to.line.compact")
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(Self.accessibilityIdentifier)
                .accessibilityLabel(Text(localized: Self.titleKey))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }
}

#if DEBUG
struct ReaderInteractionComponents_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            ReaderSelectionActionFloater(
                model: ReaderSelectionActionFloaterModel(
                    sentence: SentenceSpan(id: "0:0", text: "Sentence.", startChar: 0, endChar: 9),
                    paragraphFirstSentence: SentenceSpan(id: "0:0", text: "Sentence.", startChar: 0, endChar: 9),
                    onPlaySentence: { _ in },
                    onPlayParagraph: { _ in }
                )
            )
            ReaderFollowButton(isVisible: true, action: {})
        }
        .padding()
    }
}
#endif
