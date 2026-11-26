#if os(macOS)
import AppKit

@MainActor
final class MacSidebarPresentation {
    enum Destination: Int, CaseIterable {
        case library = 0, jobs = 1, settings = 2, convert = 3

        /// The iPhone's tabs, in its order. As on Linux, the conversions list opens from Convert.
        static let tabs: [Destination] = [.library, .settings, .convert]

        var tab: Destination { self == .jobs ? .convert : self }
        var title: String {
            switch self {
            case .library: return L10n.string("nav.library")
            case .convert: return L10n.string("convert.title")
            case .jobs: return L10n.string("jobs.title")
            case .settings: return L10n.string("nav.settings")
            }
        }
        var icon: String {
            switch self {
            case .library: return "books.vertical"
            case .convert: return "wand.and.stars"
            case .jobs: return "arrow.triangle.2.circlepath"
            case .settings: return "gearshape"
            }
        }
    }

    private var sidebarButtons: [Destination: NSButton] = [:]
    let controller = NSViewController()

    init(actionTarget: AnyObject, action: Selector) {
        configureSidebar(actionTarget: actionTarget, action: action)
    }

    private func configureSidebar(actionTarget: AnyObject, action: Selector) {
        let title = NSTextField(labelWithString: L10n.string("app.name"))
        title.font = .boldSystemFont(ofSize: 16)
        let menu = NSStackView()
        menu.orientation = .vertical
        menu.alignment = .leading
        menu.spacing = 4
        for destination in Destination.tabs {
            let button = NSButton(title: destination.title, target: actionTarget, action: action)
            button.tag = destination.rawValue
            button.alignment = .left
            button.image = NSImage(systemSymbolName: destination.icon, accessibilityDescription: destination.title)
            button.imagePosition = .imageLeading
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.isBordered = false
            button.focusRingType = .none
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.contentTintColor = .secondaryLabelColor
            button.setAccessibilityLabel(destination.title)
            sidebarButtons[destination] = button
            menu.addArrangedSubview(button)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        let stack = NSStackView(views: [title, menu, spacer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 12, bottom: 12, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // The sidebar is full height under the titlebar; keep its content
        // below the toolbar's sidebar section that holds the toggle.
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        controller.view = container
    }

    func select(_ destination: Destination) {
        for (candidate, button) in sidebarButtons {
            let selected = candidate == destination.tab
            button.state = selected ? .on : .off
            button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
            button.layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
                : NSColor.clear.cgColor
        }
    }

}
#endif
