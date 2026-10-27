#if os(iOS)
import UIKit

/// Measures bounded metadata and native controls before allocating decorative
/// cover space. The container has no scroll surface or offscreen content.
@MainActor
final class FullPlayerLayoutView: UIView {
    private let cover: UIView
    private let metadata: UIStackView
    private let playback: UIStackView
    private let secondary: UIStackView
    private let spacing = FullPlayerLayoutMetrics.elementSpacing

    init(cover: UIView, metadata: UIStackView, playback: UIStackView, secondary: UIStackView) {
        self.cover = cover
        self.metadata = metadata
        self.playback = playback
        self.secondary = secondary
        super.init(frame: .zero)
        for child in [cover, metadata, playback, secondary] {
            child.translatesAutoresizingMaskIntoConstraints = true
            addSubview(child)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let horizontal = bounds.width > bounds.height && bounds.width >= 480
        let controlsWidth = horizontal ? max(260, bounds.width * 0.56) : bounds.width
        let metadataWidth = horizontal ? bounds.width - controlsWidth - 16 : bounds.width
        let metadataHeight = fittingHeight(metadata, width: metadataWidth)
        let playbackHeight = fittingHeight(playback, width: controlsWidth)
        let secondaryHeight = max(44, fittingHeight(secondary, width: controlsWidth))
        let controlsHeight = playbackHeight + spacing + secondaryHeight
        let controlsX = horizontal ? metadataWidth + 16 : 0
        let controlsY = bounds.height - controlsHeight
        playback.frame = CGRect(x: controlsX, y: controlsY, width: controlsWidth, height: playbackHeight)
        secondary.frame = CGRect(x: controlsX, y: bounds.height - secondaryHeight,
                                 width: controlsWidth, height: secondaryHeight)
        let metadataY = horizontal ? bounds.height - metadataHeight : controlsY - spacing - metadataHeight
        metadata.frame = CGRect(x: 0, y: metadataY, width: metadataWidth, height: metadataHeight)
        let coverHeight = max(0, min(metadataWidth * 0.7 * 1.5, metadataY - spacing))
        let coverWidth = coverHeight / 1.5
        cover.frame = CGRect(x: (metadataWidth - coverWidth) / 2, y: 0,
                             width: coverWidth, height: coverHeight)
        cover.isHidden = coverHeight < 1
    }

    private func fittingHeight(_ stack: UIStackView, width: CGFloat) -> CGFloat {
        ceil(stack.systemLayoutSizeFitting(CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height)
    }
}
#endif
