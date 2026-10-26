import Foundation
#if os(macOS)
import AppKit
typealias RecoveryStack = NSStackView
#else
import UIKit
typealias RecoveryStack = UIStackView
#endif

@MainActor
final class BookConversionRecoveryPanel: RecoveryStack {
    var onResume: ((ConversionOptions) -> Void)?
    private var record: BookConversionRecoveryStore.Record?
    private var refreshTask: Task<Void, Never>?
    #if os(macOS)
    private let label = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton()
    #else
    private let label = UILabel()
    private let button = UIButton(type: .system)
    #endif

    init() {
        super.init(frame: .zero)
        #if os(macOS)
        orientation = .vertical
        label.textColor = .secondaryLabelColor
        button.title = L10n.string("bookRecovery.resume")
        button.target = self
        button.action = #selector(resume)
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier("bookRecovery.resume")
        #else
        axis = .vertical
        label.numberOfLines = 0
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        button.setTitle(L10n.string("bookRecovery.resume"), for: .normal)
        button.addTarget(self, action: #selector(resume), for: .touchUpInside)
        button.accessibilityIdentifier = "bookRecovery.resume"
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        #endif
        spacing = 8
        addArrangedSubview(label)
        addArrangedSubview(button)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { refreshTask?.cancel() }

    func refresh(bookID: String) {
        refreshTask?.cancel()
        record = nil
        isHidden = true
        refreshTask = Task { [weak self] in
            let pending = try? await BookConversionRecoveryStore.shared.pending(bookID: bookID)
            guard let self, !Task.isCancelled, let pending else { return }
            record = pending
            let title = pending.chaptersTotal > 0
                ? L10n.string("bookRecovery.partial", pending.completed.count, pending.chaptersTotal)
                : L10n.string("bookRecovery.interrupted")
            #if os(macOS)
            label.stringValue = title
            #else
            label.text = title
            #endif
            isHidden = false
        }
    }

    @objc private func resume() {
        guard let record else { return }
        isHidden = true
        onResume?(record.resumeOptions)
    }
}
