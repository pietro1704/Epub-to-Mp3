#if os(iOS)
import UIKit

@MainActor
final class ReaderEmptyPresentation {
    private var emptyStateScrollView: UIScrollView?
    private let emptyStateStack = UIStackView()
    private let emptyTitleLabel = UILabel()
    private let emptyDescriptionLabel = UILabel()
    private let browseButton = UIButton(type: .system)
    let listenButton = UIButton(type: .system)

    func install(in view: UIView, target: AnyObject, browseAction: Selector, listenAction: Selector) {
        emptyStateStack.axis = .vertical
        emptyStateStack.spacing = 20
        emptyStateStack.alignment = .center
        emptyStateStack.translatesAutoresizingMaskIntoConstraints = false

        emptyTitleLabel.font = .preferredFont(forTextStyle: .title2)
        emptyTitleLabel.adjustsFontForContentSizeCategory = true
        emptyTitleLabel.numberOfLines = 0
        emptyTitleLabel.textAlignment = .center
        emptyTitleLabel.text = L10n.string("mainReader.pickBook")

        emptyDescriptionLabel.font = .preferredFont(forTextStyle: .body)
        emptyDescriptionLabel.adjustsFontForContentSizeCategory = true
        emptyDescriptionLabel.textColor = .secondaryLabel
        emptyDescriptionLabel.numberOfLines = 0
        emptyDescriptionLabel.textAlignment = .center
        emptyDescriptionLabel.text = L10n.string("mainReader.pickBookDescription")

        var browseConfig = UIButton.Configuration.filled()
        browseConfig.image = UIImage(systemName: "books.vertical")
        browseConfig.imagePadding = 8
        browseConfig.title = L10n.string("mainReader.browseLibrary")
        browseButton.configuration = browseConfig
        browseButton.addTarget(target, action: browseAction, for: .touchUpInside)
        browseButton.accessibilityIdentifier = "mainReader.browseLibrary"

        [emptyTitleLabel, emptyDescriptionLabel, browseButton].forEach { emptyStateStack.addArrangedSubview($0) }
        emptyStateStack.alignment = .fill
        browseButton.titleLabel?.numberOfLines = 0
        browseButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        emptyStateScrollView = IOSScrollableStack.install(emptyStateStack, in: view)

        // Playback is controlled exclusively from the persistent mini-player.
        // A second "Listen" button here duplicated the control and pushed the
        // reader content into an inconsistent layout while a book was loading.
        listenButton.isHidden = true
        listenButton.translatesAutoresizingMaskIntoConstraints = false
        listenButton.accessibilityIdentifier = "mainReader.listen"
        listenButton.addTarget(target, action: listenAction, for: .touchUpInside)
    }

    var isHidden: Bool {
        get { emptyStateStack.isHidden }
        set {
            emptyStateScrollView?.isHidden = newValue
            emptyStateStack.isHidden = newValue
        }
    }

    func applyColors(foreground: UIColor) {
        emptyTitleLabel.textColor = foreground
        emptyDescriptionLabel.textColor = foreground.withAlphaComponent(0.75)
    }
}
#endif
