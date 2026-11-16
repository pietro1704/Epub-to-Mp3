#if os(iOS)
import UIKit

/// UIKit keeps ownership of selection. Older systems expose app commands through
/// their native editing menu and route More to a contextual action sheet.
final class ReaderSelectionTextView: UITextView {
    var onLegacyCommand: ((Bool, NSRange) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if #available(iOS 16.0, *) { return accepted }
        if accepted {
            UIMenuController.shared.menuItems = [
                UIMenuItem(title: L10n.string("reader.action.playFromHere"), action: #selector(playFromSelection)),
                UIMenuItem(title: L10n.string("reader.selection.more"), action: #selector(moreSelectionActions))
            ]
        }
        return accepted
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(playFromSelection) || action == #selector(moreSelectionActions) {
            return selectedRange.length > 0 && onLegacyCommand != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func playFromSelection() { onLegacyCommand?(false, selectedRange) }
    @objc private func moreSelectionActions() { onLegacyCommand?(true, selectedRange) }
}
#endif
