#if os(macOS)
import AppKit

@MainActor
final class MacSidebarPresentation {
    enum Destination: Int, CaseIterable {
        case library, jobs, settings
        var title: String {
            switch self {
            case .library: return L10n.string("nav.library")
            case .jobs: return L10n.string("nav.conversions")
            case .settings: return L10n.string("nav.settings")
            }
        }
        var icon: String {
            switch self {
            case .library: return "books.vertical"
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
        for destination in Destination.allCases {
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
        controller.view = stack
    }

    func select(_ destination: Destination) {
        for (candidate, button) in sidebarButtons {
            let selected = candidate == destination
            button.state = selected ? .on : .off
            button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
            button.layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
                : NSColor.clear.cgColor
        }
    }

}
#endif
