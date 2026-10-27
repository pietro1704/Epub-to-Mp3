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
    private(set) var layoutView: FullPlayerLayoutView!

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

        titleLabel.font = UIFontMetrics(forTextStyle: .title2).scaledFont(
            for: .systemFont(ofSize: 22, weight: .bold), maximumPointSize: 38, compatibleWith: traits)
        titleLabel.numberOfLines = 2
        titleLabel.textAlignment = .center
        titleLabel.accessibilityIdentifier = "fullPlayer.bookTitle"

        authorLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 15), maximumPointSize: 24, compatibleWith: traits)
        authorLabel.numberOfLines = 1
        authorLabel.textColor = .secondaryLabel
        authorLabel.textAlignment = .center
        authorLabel.accessibilityIdentifier = "fullPlayer.bookAuthor"

        chapterLabel.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .systemFont(ofSize: 13), maximumPointSize: 20, compatibleWith: traits)
        chapterLabel.textColor = .tertiaryLabel
        chapterLabel.numberOfLines = 2
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

        slider.addTarget(actionTarget, action: actions.scrubBegan, for: .touchDown)
        slider.addTarget(actionTarget, action: actions.scrubChanged, for: .valueChanged)
        slider.addTarget(actionTarget, action: actions.scrubEnded, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        slider.addTarget(actionTarget, action: actions.scrubEnded, for: .editingDidEnd)

        [elapsedLabel, remainingLabel].forEach {
            $0.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), maximumPointSize: 20, compatibleWith: traits)
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
        playPauseButton.accessibilityIdentifier = "fullPlayer.playPause"
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
        rateConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFontMetrics(forTextStyle: .body).scaledFont(
                for: .systemFont(ofSize: 17), maximumPointSize: 20, compatibleWith: traits)
            return outgoing
        }
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

        let metadata = UIStackView(arrangedSubviews: [titleLabel, authorLabel, chapterLabel])
        metadata.axis = .vertical
        metadata.spacing = FullPlayerLayoutMetrics.elementSpacing

        layoutView = FullPlayerLayoutView(cover: coverContainer, metadata: metadata,
            playback: playbackControls, secondary: secondary)
        layoutView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(layoutView)
        view.bringSubviewToFront(dragHandle)
        view.bringSubviewToFront(closeButton)
        NSLayoutConstraint.activate([
            dragHandle.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            dragHandle.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            dragHandle.widthAnchor.constraint(equalToConstant: 36),
            dragHandle.heightAnchor.constraint(equalToConstant: 5),
            closeButton.topAnchor.constraint(equalTo: dragHandle.bottomAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            layoutView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            layoutView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            layoutView.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 8),
            layoutView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            secondary.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            volumeView.heightAnchor.constraint(equalToConstant: 34),
        ])
        let controls = [previousChapterButton, skipBackButton, playPauseButton,
                        skipForwardButton, nextChapterButton, rateButton, tocButton, sleepButton]
        for control in controls {
            NSLayoutConstraint.activate([
                control.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
                control.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            ])
        }
    }
}
#endif
