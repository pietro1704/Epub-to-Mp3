#if os(iOS)
import AVKit
import MediaPlayer
import UIKit

enum FullPlayerLayoutMetrics {
    static let elementSpacing: CGFloat = 4
    static let bottomInset: CGFloat = 0
}

struct FullPlayerControlActions {
    let closeTapped: Selector
    let scrubBegan: Selector
    let scrubChanged: Selector
    let scrubEnded: Selector
    let previousChapterTapped: Selector
    let skipBackTapped: Selector
    let playPauseTapped: Selector
    let skipForwardTapped: Selector
    let nextChapterTapped: Selector
    let tocTapped: Selector
}

@MainActor
final class FullPlayerContent {
    let closeButton = UIButton(type: .system)
    let dragHandle = UIView()
    let coverContainer = UIView()
    let coverImageView = UIImageView()
    let titleLabel = UILabel()
    let authorLabel = UILabel()
    let chapterLabel = UILabel()
    let slider = CompactSlider()
    let elapsedLabel = UILabel()
    let remainingLabel = UILabel()
    let previousChapterButton = UIButton(type: .system)
    let skipBackButton = UIButton(type: .system)
    let playPauseButton = UIButton(type: .system)
    let skipForwardButton = UIButton(type: .system)
    let nextChapterButton = UIButton(type: .system)
    let rateButton = UIButton(type: .system)
    let tocButton = UIButton(type: .system)
    let sleepButton = UIButton(type: .system)
    let airPlayContainer = UIView()
    // The legacy route-button configuration is intentionally omitted.
    // since iOS 13 (this project builds with SWIFT_TREAT_WARNINGS_AS_ERRORS,
    // so the deprecation is a hard build failure, not just a warning).
    // `AVRoutePickerView` is Apple's replacement and is exactly an AirPlay
    // route button by design — no extra config needed to hide the volume
    // slider like MPVolumeView required.
    let airPlayView = AVRoutePickerView(frame: .zero)
    let volumeView = MPVolumeView(frame: .zero)
    let contentScrollView = UIScrollView()
    let stackView = UIStackView()

    func install(in view: UIView, actionTarget: AnyObject, actions: FullPlayerControlActions, traits: UITraitCollection) {
        let background = AdaptiveMaterialView()
        view.addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            background.topAnchor.constraint(equalTo: view.topAnchor),
            background.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // HIG-standard grabber affordance signalling "this can be dragged" —
        // purely visual, the pan gesture is attached to `view` itself (see
        // viewDidLoad) so dragging also works from the background/labels.
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        dragHandle.backgroundColor = .tertiaryLabel
        dragHandle.layer.cornerRadius = 2.5
        dragHandle.isUserInteractionEnabled = false
        dragHandle.accessibilityIdentifier = "fullPlayer.dragHandle"
        view.addSubview(dragHandle)

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .label
        closeButton.addTarget(actionTarget, action: actions.closeTapped, for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.accessibilityIdentifier = "fullPlayer.close"
        closeButton.accessibilityLabel = L10n.string("player.close")
        view.addSubview(closeButton)

        coverContainer.translatesAutoresizingMaskIntoConstraints = false
        coverContainer.layer.cornerRadius = 16
        coverContainer.layer.masksToBounds = true
        coverContainer.backgroundColor = UIColor.tintColor.withAlphaComponent(0.15)

        coverImageView.translatesAutoresizingMaskIntoConstraints = false
        coverImageView.contentMode = .scaleAspectFit
        coverImageView.image = UIImage(systemName: "headphones")
        coverImageView.tintColor = .tintColor
        coverContainer.addSubview(coverImageView)
        NSLayoutConstraint.activate([
            coverImageView.leadingAnchor.constraint(equalTo: coverContainer.leadingAnchor),
            coverImageView.trailingAnchor.constraint(equalTo: coverContainer.trailingAnchor),
            coverImageView.topAnchor.constraint(equalTo: coverContainer.topAnchor),
            coverImageView.bottomAnchor.constraint(equalTo: coverContainer.bottomAnchor),
        ])

        titleLabel.font = .preferredFont(forTextStyle: .title2, compatibleWith: traits).bold()
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center
        titleLabel.accessibilityIdentifier = "fullPlayer.bookTitle"

        authorLabel.font = .preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        authorLabel.numberOfLines = 0
        authorLabel.textColor = .secondaryLabel
        authorLabel.textAlignment = .center
        authorLabel.accessibilityIdentifier = "fullPlayer.bookAuthor"

        chapterLabel.font = .preferredFont(forTextStyle: .footnote, compatibleWith: traits)
        chapterLabel.textColor = .tertiaryLabel
        chapterLabel.numberOfLines = 0
        chapterLabel.textAlignment = .center

        [titleLabel, authorLabel, chapterLabel].forEach { $0.adjustsFontForContentSizeCategory = true }

        // Keep the book and chapter metadata visible on compact iPhone
        // heights. Without explicit vertical priorities, the stack can
        // compress these labels to zero while preserving the cover and
        // transport controls.
        titleLabel.setContentHuggingPriority(.required, for: .vertical)
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        authorLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        chapterLabel.setContentHuggingPriority(.required, for: .vertical)
        chapterLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        titleLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
        chapterLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
        authorLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 18).isActive = true

        slider.addTarget(actionTarget, action: actions.scrubBegan, for: .touchDown)
        slider.addTarget(actionTarget, action: actions.scrubChanged, for: .valueChanged)
        slider.addTarget(actionTarget, action: actions.scrubEnded, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        slider.addTarget(actionTarget, action: actions.scrubEnded, for: .editingDidEnd)

        [elapsedLabel, remainingLabel].forEach {
            $0.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedDigitSystemFont(ofSize: 12, weight: .regular))
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = .secondaryLabel
        }
        slider.accessibilityIdentifier = "fullPlayer.progress"
        slider.accessibilityLabel = L10n.string("player.playbackPosition")
        elapsedLabel.accessibilityIdentifier = "fullPlayer.elapsed"
        remainingLabel.accessibilityIdentifier = "fullPlayer.remaining"

        PlayerTransportPresentation.configureTransportButton(previousChapterButton, actionTarget: actionTarget, image: "backward.end.fill", action: actions.previousChapterTapped)
        previousChapterButton.accessibilityIdentifier = "fullPlayer.previousChapter"
        PlayerTransportPresentation.configureTransportButton(skipBackButton, actionTarget: actionTarget, image: "gobackward.15", action: actions.skipBackTapped, pointSize: 28)
        skipBackButton.accessibilityIdentifier = "fullPlayer.skipBack"
        PlayerTransportPresentation.configureTransportButton(playPauseButton, actionTarget: actionTarget, image: "play.fill", action: actions.playPauseTapped, pointSize: 64)
        let playWidth = playPauseButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64)
        let playHeight = playPauseButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 64)
        playWidth.priority = .required - 2
        playHeight.priority = .required - 2
        NSLayoutConstraint.activate([playWidth, playHeight])
        PlayerTransportPresentation.configureTransportButton(skipForwardButton, actionTarget: actionTarget, image: "goforward.15", action: actions.skipForwardTapped, pointSize: 28)
        skipForwardButton.accessibilityIdentifier = "fullPlayer.skipForward"
        PlayerTransportPresentation.configureTransportButton(nextChapterButton, actionTarget: actionTarget, image: "forward.end.fill", action: actions.nextChapterTapped)
        nextChapterButton.accessibilityIdentifier = "fullPlayer.nextChapter"

        let transport = UIStackView(arrangedSubviews: [
            previousChapterButton, skipBackButton, playPauseButton, skipForwardButton, nextChapterButton
        ])
        transport.axis = .horizontal
        transport.alignment = .center
        transport.distribution = .equalSpacing
        transport.spacing = FullPlayerLayoutMetrics.elementSpacing

        var rateConfig = UIButton.Configuration.plain()
        rateConfig.contentInsets = .init(top: 8, leading: 12, bottom: 8, trailing: 12)
        rateConfig.background.backgroundColor = .secondarySystemFill
        rateConfig.background.cornerRadius = 10
        rateButton.configuration = rateConfig
        rateButton.translatesAutoresizingMaskIntoConstraints = false
        rateButton.accessibilityIdentifier = "fullPlayer.playbackRateButton"
        rateButton.accessibilityLabel = L10n.string("player.speed")
        rateButton.showsMenuAsPrimaryAction = true

        PlayerTransportPresentation.configureSecondaryButton(tocButton, actionTarget: actionTarget, image: "list.bullet", title: nil, action: actions.tocTapped)
        PlayerTransportPresentation.configureSecondaryButton(sleepButton, actionTarget: actionTarget, image: "moon.zzz", title: nil, action: nil)
        tocButton.accessibilityLabel = L10n.string("reader.toc")
        sleepButton.showsMenuAsPrimaryAction = true

        airPlayView.translatesAutoresizingMaskIntoConstraints = false
        airPlayContainer.translatesAutoresizingMaskIntoConstraints = false
        airPlayContainer.addSubview(airPlayView)
        // Same narrow-screen conflict as the transport/secondary buttons —
        // a hard `== 44` here left Auto Layout no room to shrink and forced
        // it to break an arbitrary constraint elsewhere in the row instead.
        let airPlayWidth = airPlayContainer.widthAnchor.constraint(equalToConstant: 44)
        let airPlayHeight = airPlayContainer.heightAnchor.constraint(equalToConstant: 44)
        airPlayWidth.priority = .required - 1
        airPlayHeight.priority = .required - 1
        NSLayoutConstraint.activate([
            airPlayView.leadingAnchor.constraint(equalTo: airPlayContainer.leadingAnchor),
            airPlayView.trailingAnchor.constraint(equalTo: airPlayContainer.trailingAnchor),
            airPlayView.topAnchor.constraint(equalTo: airPlayContainer.topAnchor),
            airPlayView.bottomAnchor.constraint(equalTo: airPlayContainer.bottomAnchor),
            airPlayWidth,
            airPlayHeight,
        ])

        let secondary = UIStackView(arrangedSubviews: [rateButton, UIView(), tocButton, sleepButton, airPlayContainer])
        secondary.axis = .horizontal
        secondary.alignment = .center
        secondary.spacing = FullPlayerLayoutMetrics.elementSpacing
        secondary.translatesAutoresizingMaskIntoConstraints = false

        volumeView.showsVolumeSlider = true
        volumeView.translatesAutoresizingMaskIntoConstraints = false

        let timeRow = UIStackView(arrangedSubviews: [elapsedLabel, UIView(), remainingLabel])
        timeRow.axis = .horizontal
        timeRow.alignment = .fill

        let playbackControls = UIStackView(arrangedSubviews: [
            slider, timeRow, transport, volumeView
        ])
        playbackControls.axis = .vertical
        playbackControls.alignment = .fill
        playbackControls.spacing = FullPlayerLayoutMetrics.elementSpacing
        playbackControls.translatesAutoresizingMaskIntoConstraints = false

        // `coverContainer` must NOT be an arranged subview directly: the
        // vertical stack's default `.fill` alignment pins every arranged
        // subview's leading/trailing to the stack's own edges (full width),
        // which unconditionally contradicts the explicit 0.7-multiplier
        // width + centerX constraints below — "Unable to simultaneously
        // satisfy constraints" on every single appearance, regardless of
        // device width. A plain full-width wrapper absorbs the stack's fill
        // pinning; `coverContainer` sizes itself against the wrapper instead.
        let coverRow = UIView()
        coverRow.translatesAutoresizingMaskIntoConstraints = false
        coverRow.addSubview(coverContainer)

        stackView.axis = .vertical
        stackView.spacing = FullPlayerLayoutMetrics.elementSpacing
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(coverRow)

        let metadata = UIStackView(arrangedSubviews: [titleLabel, authorLabel, chapterLabel])
        metadata.axis = .vertical
        metadata.alignment = .fill
        metadata.spacing = FullPlayerLayoutMetrics.elementSpacing
        metadata.translatesAutoresizingMaskIntoConstraints = false

        // Keep controls together and allow the whole player to scroll when text grows.
        let bottomContent = UIStackView(arrangedSubviews: [metadata, playbackControls, secondary])
        bottomContent.axis = .vertical
        bottomContent.alignment = .fill
        bottomContent.spacing = FullPlayerLayoutMetrics.elementSpacing
        bottomContent.translatesAutoresizingMaskIntoConstraints = false

        contentScrollView.translatesAutoresizingMaskIntoConstraints = false
        contentScrollView.alwaysBounceVertical = false
        contentScrollView.showsVerticalScrollIndicator = false
        contentScrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(contentScrollView)
        let flexibleSpace = UIView()
        flexibleSpace.setContentHuggingPriority(.defaultLow, for: .vertical)
        stackView.addArrangedSubview(flexibleSpace)
        stackView.addArrangedSubview(bottomContent)
        contentScrollView.addSubview(stackView)
        view.bringSubviewToFront(dragHandle)
        view.bringSubviewToFront(closeButton)

        let preferredCoverWidth = coverContainer.widthAnchor.constraint(
            equalTo: coverRow.widthAnchor,
            multiplier: 0.7
        )
        preferredCoverWidth.priority = .defaultLow
        let preferredContentHeight = stackView.heightAnchor.constraint(equalTo: contentScrollView.frameLayoutGuide.heightAnchor)
        preferredContentHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            dragHandle.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            dragHandle.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            dragHandle.widthAnchor.constraint(equalToConstant: 36),
            dragHandle.heightAnchor.constraint(equalToConstant: 5),

            closeButton.topAnchor.constraint(equalTo: dragHandle.bottomAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            contentScrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            contentScrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            contentScrollView.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 8),
            contentScrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                                                     constant: -FullPlayerLayoutMetrics.bottomInset),
            preferredContentHeight,
            stackView.heightAnchor.constraint(greaterThanOrEqualTo: contentScrollView.frameLayoutGuide.heightAnchor),
            secondary.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            stackView.leadingAnchor.constraint(equalTo: contentScrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentScrollView.contentLayoutGuide.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: contentScrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: contentScrollView.contentLayoutGuide.bottomAnchor),
            stackView.widthAnchor.constraint(equalTo: contentScrollView.frameLayoutGuide.widthAnchor),

            preferredCoverWidth,
            coverContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 72),
            coverContainer.heightAnchor.constraint(equalTo: coverContainer.widthAnchor, multiplier: 1.5),
            coverContainer.heightAnchor.constraint(
                lessThanOrEqualTo: contentScrollView.frameLayoutGuide.heightAnchor,
                multiplier: 0.70
            ),
            coverContainer.topAnchor.constraint(equalTo: coverRow.topAnchor),
            coverContainer.bottomAnchor.constraint(equalTo: coverRow.bottomAnchor),
            coverContainer.centerXAnchor.constraint(equalTo: coverRow.centerXAnchor),
            volumeView.heightAnchor.constraint(equalToConstant: 34),
        ])
    }


}

private extension UIFont {
    func bold() -> UIFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) ?? fontDescriptor
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif
