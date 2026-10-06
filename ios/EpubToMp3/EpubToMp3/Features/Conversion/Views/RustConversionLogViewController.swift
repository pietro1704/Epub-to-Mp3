import Foundation

#if os(macOS)
import AppKit
final class RustConversionLogViewController: NSViewController {
    private let logURL: URL
    private let textView = NSTextView()
    private var timer: Timer?
    init(logURL: URL) { self.logURL = logURL; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = NSView() }
    override func viewDidLoad() {
        super.viewDidLoad(); title = L10n.string("conversion.log")
        textView.isEditable = false; textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let scroll = NSScrollView(); scroll.documentView = textView; scroll.hasVerticalScroller = true; scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll); NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        refresh(); timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
    }
    private func refresh() { guard let data = try? Data(contentsOf: logURL), let text = String(data: data, encoding: .utf8) else { return }; textView.string = text; textView.scrollToEndOfDocument(nil) }
    deinit { timer?.invalidate() }
}
#elseif os(iOS)
import UIKit
final class RustConversionLogViewController: UIViewController {
    private let logURL: URL
    private let textView = UITextView()
    private var timer: Timer?
    init(logURL: URL) { self.logURL = logURL; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = L10n.string("conversion.log"); view.backgroundColor = .systemBackground
        textView.isEditable = false; textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular); textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView); NSLayoutConstraint.activate([textView.leadingAnchor.constraint(equalTo: view.leadingAnchor), textView.trailingAnchor.constraint(equalTo: view.trailingAnchor), textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), textView.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        refresh(); timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
    }
    private func refresh() { guard let data = try? Data(contentsOf: logURL), let text = String(data: data, encoding: .utf8) else { return }; textView.text = text; textView.scrollRangeToVisible(NSRange(location: text.utf16.count, length: 0)) }
    deinit { timer?.invalidate() }
}
#endif
