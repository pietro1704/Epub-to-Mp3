#if os(iOS)
import UIKit

/// Reader typography/theme/layout controls ("Aa"), presented as a floating
/// modal sheet from `BookOpenScreenController.presentReaderSettings()` —
/// never inline in the reader's own layout. Ported from the deleted
/// SwiftUI-era UIKit screen (see commit `8c617f98^` for the last version)
/// with a single addition: `onChange`, fired whenever a setting is edited,
/// so the presenting reader can live-update font/theme/alignment/line
/// spacing while this sheet is still on screen.
@MainActor
final class ReaderSettingsScreenController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case theme
        case font
        case layout
        case audioTracking
    }

    private let settings: AppSettings
    private let isPDF: Bool

    /// Fired at the end of every `refresh()` — i.e. right after any setting
    /// changes — so the reader behind this sheet can re-render immediately.
    var onChange: (() -> Void)?

    /// The presenting reader can refresh window-coordinate diagnostics only
    /// after the sheet has restored its final presentation transform.
    var onDismiss: (() -> Void)?

    init(settings: AppSettings, isPDF: Bool = false) {
        self.settings = settings
        self.isPDF = isPDF
        super.init(style: .insetGrouped)
        title = L10n.string("readerSettings.title")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.cellLayoutMarginsFollowReadableWidth = true
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.accessibilityLabel = L10n.string("readerSettings.title")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        installScopeHeader()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.string("readerSettings.done"),
            style: .done,
            target: self,
            action: #selector(doneTapped)
        )
    }

    /// The mode on top (default for every book, or this book only) and, with a book open, the choice to keep these
    /// settings for this book only (READING-PREFERENCES).
    private func installScopeHeader() {
        guard settings.isInBookScope else { tableView.tableHeaderView = nil; return }
        let mode = UILabel()
        mode.text = L10n.string(settings.readingPreferenceModeTitleKey)
        mode.font = .preferredFont(forTextStyle: .headline)
        mode.numberOfLines = 0
        mode.accessibilityIdentifier = "readerSettings.scope.mode"
        mode.accessibilityTraits = .header
        let hint = UILabel()
        hint.text = L10n.string(settings.readingPreferenceModeHintKey)
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.textColor = .secondaryLabel
        hint.numberOfLines = 0
        let toggleLabel = UILabel()
        toggleLabel.text = L10n.string("readerSettings.scope.toggle")
        toggleLabel.font = .preferredFont(forTextStyle: .body)
        toggleLabel.numberOfLines = 0
        let toggle = UISwitch()
        toggle.isOn = settings.isBookSpecific
        toggle.accessibilityIdentifier = "readerSettings.scope.bookOnly"
        toggle.accessibilityLabel = toggleLabel.text
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            guard let self, let toggle else { return }
            if toggle.isOn { self.settings.useOnlyForThisBook() } else { self.settings.useDefaultForThisBook() }
            self.refresh()
        }, for: .valueChanged)
        let toggleRow = UIStackView(arrangedSubviews: [toggleLabel, toggle])
        toggleRow.spacing = 12
        toggleRow.alignment = .center
        let stack = UIStackView(arrangedSubviews: [mode, hint, toggleRow])
        stack.axis = .vertical
        stack.spacing = 8
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        let width = tableView.bounds.width > 0 ? tableView.bounds.width : 390
        let size = stack.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                 withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        stack.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
        tableView.tableHeaderView = stack
    }

    func refresh() {
        guard isViewLoaded else { return }
        installScopeHeader()
        tableView.reloadData()
        onChange?()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else { return 0 }
        switch section {
        case .theme:
            return ReaderTheme.allCases.filter { $0 != .custom }.count
        case .font:
            return isPDF ? 0 : 2
        case .layout:
            if isPDF { return 2 }
            return settings.readerLayout == .paginated ? 6 : 4
        case .audioTracking:
            return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .theme: return L10n.string("readerSettings.theme")
        case .font: return isPDF ? nil : L10n.string("readerSettings.font")
        case .layout: return L10n.string("readerSettings.layout")
        case .audioTracking: return L10n.string("settings.playback")
        }
    }

override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    guard let section = Section(rawValue: indexPath.section) else { return UITableViewCell() }
    if (section == .font && indexPath.row == 1)
        || (section == .layout && isSliderLayoutRow(indexPath.row)) {
        let font = section == .font
        let spacing = !font && indexPath.row == (settings.readerLayout == .paginated ? 4 : 2)
        let key = font ? "size" : (spacing ? "lineSpacing" : "margin")
        let identifier = font ? "fontSize" : (spacing ? "lineSpacing" : "margin")
        let presets = font ? PointPresetScale.font : (spacing ? PointPresetScale.lineSpacing : PointPresetScale.margin)
        let current = font ? Double(settings.readerPointSize) : (spacing ? settings.readerLineSpacing : settings.readerMargin)
        return PointPresetCell.make(in: tableView, title: L10n.string("readerSettings." + key),
            identifier: "reader.settings." + identifier, presets: presets, current: current) { [weak self] value in
            guard let self else { return }
            if font { self.settings.readerFontSize = PointPresetScale.nearestIndex(to: value, in: PointPresetScale.font) }
            else if spacing { self.settings.readerLineSpacing = value }
            else { self.settings.readerMargin = value }
            self.onChange?()
        }
    }
    let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
    cell.accessibilityIdentifier = nil
    cell.accessoryView = nil
    cell.accessoryType = .none
    var content = cell.defaultContentConfiguration()
    switch section {
    case .theme:
        let themes = ReaderTheme.allCases.filter { $0 != .custom }
        let theme = themes[indexPath.row]
        content.text = theme.displayName
        content.image = Self.themePreviewImage(for: theme)
        cell.accessoryType = settings.readerTheme == theme ? .checkmark : .none
    case .font:
        cell.accessibilityIdentifier = "reader.settings.fontFamily"
        content.text = L10n.string("readerSettings.family")
        content.secondaryText = ReaderFontCatalog.title(for: settings.selectedReaderFontFamily)
        cell.accessoryType = .disclosureIndicator
    case .audioTracking:
        content.text = L10n.string("readerSettings.audioTracking")
        content.secondaryText = L10n.string("readerSettings.audioTrackingDescription")
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        cell.accessibilityIdentifier = "reader.settings.audioTracking.row"
        let toggle = UISwitch()
        toggle.isOn = settings.readerAudioTrackingEnabled
        toggle.accessibilityIdentifier = "reader.settings.audioTracking"
        toggle.accessibilityLabel = content.text
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            guard let self, let toggle else { return }
            self.settings.readerAudioTrackingEnabled = toggle.isOn
            self.onChange?()
        }, for: .valueChanged)
        cell.accessoryView = toggle
    case .layout:
        layoutCellContent(&content, row: indexPath.row)
        cell.accessibilityIdentifier = layoutAccessibilityIdentifier(for: indexPath.row)
        cell.accessoryType = isToggleLayoutRow(indexPath.row)
            ? (settings.readerShowPageNumbers ? .checkmark : .none) : .disclosureIndicator
    }
    cell.contentConfiguration = content
    cell.accessibilityLabel = content.text
    cell.accessibilityValue = content.secondaryText ?? (section == .theme ? themeAccessibilityValue(indexPath.row) : nil)
    cell.accessibilityHint = isToggleLayoutRow(indexPath.row)
        ? L10n.string("readerSettings.toggleHint") : L10n.string("readerSettings.chooseOptionHint")
    return cell
}

    private func themeAccessibilityValue(_ row: Int) -> String {
        let themes = ReaderTheme.allCases.filter { $0 != .custom }
        let theme = themes[row]
        return settings.readerTheme == theme ? "\(theme.displayName), selected" : theme.displayName
    }

    private static func themePreviewImage(for theme: ReaderTheme) -> UIImage? {
        let colors = theme.previewColors
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32))
        return renderer.image { context in
            let rect = CGRect(x: 1, y: 1, width: 30, height: 30)
            colors.background.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 8).fill()
            colors.foreground.setStroke()
            let line = UIBezierPath()
            line.move(to: CGPoint(x: 8, y: 12)); line.addLine(to: CGPoint(x: 24, y: 12))
            line.move(to: CGPoint(x: 8, y: 18)); line.addLine(to: CGPoint(x: 20, y: 18))
            line.lineWidth = 2
            line.stroke()
            UIColor.separator.setStroke()
            UIBezierPath(roundedRect: rect, cornerRadius: 8).stroke()
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: !UIAccessibility.isReduceMotionEnabled) }
        guard let section = Section(rawValue: indexPath.section) else { return }
        switch section {
        case .theme:
            let themes = ReaderTheme.allCases.filter { $0 != .custom }
            settings.readerTheme = themes[indexPath.row]
            refresh()
        case .font:
            handleFontSelection(row: indexPath.row)
        case .layout:
            handleLayoutSelection(row: indexPath.row)
        case .audioTracking:
            settings.readerAudioTrackingEnabled.toggle()
            refresh()
        }
    }

    private func layoutCellContent(_ content: inout UIListContentConfiguration, row: Int) {
        if isPDF, row == 1 {
            content.text = L10n.string("readerSettings.showPageNumbers")
            return
        }
        let paginated = settings.readerLayout == .paginated
        if row == 0 {
            content.text = L10n.string("readerSettings.mode")
            content.secondaryText = settings.readerLayout.displayName
            return
        }
        if paginated {
            switch row {
            case 1:
                content.text = L10n.string("readerSettings.pageTurnStyle")
                content.secondaryText = settings.pageTurnStyle.displayName
            case 2:
                content.text = L10n.string("readerSettings.showPageNumbers")
                content.secondaryText = nil
            case 3:
                content.text = L10n.string("readerSettings.alignment")
                content.secondaryText = settings.readerTextAlignment.displayName
            case 4:
                content.text = L10n.string("readerSettings.lineSpacing")
                content.secondaryText = "\(Int(settings.readerLineSpacing))"
            default:
                content.text = L10n.string("readerSettings.margin")
                content.secondaryText = "\(Int(settings.readerMargin))pt"
            }
        } else {
            switch row {
            case 1:
                content.text = L10n.string("readerSettings.alignment")
                content.secondaryText = settings.readerTextAlignment.displayName
            case 2:
                content.text = L10n.string("readerSettings.lineSpacing")
                content.secondaryText = "\(Int(settings.readerLineSpacing))"
            default:
                content.text = L10n.string("readerSettings.margin")
                content.secondaryText = "\(Int(settings.readerMargin))pt"
            }
        }
    }

    private func isToggleLayoutRow(_ row: Int) -> Bool {
        isPDF ? row == 1 : settings.readerLayout == .paginated && row == 2
    }

    private func layoutAccessibilityIdentifier(for row: Int) -> String {
        let paginated = settings.readerLayout == .paginated
        switch row {
        case 0:
            return "reader.settings.mode"
        case paginated ? 4 : 2:
            return "reader.settings.lineSpacing.row"
        case paginated ? 5 : 3:
            return "reader.settings.margin.row"
        default:
            return "reader.settings.layout.row.\(row)"
        }
    }

    private func isSliderLayoutRow(_ row: Int) -> Bool {
        if isPDF { return false }
        return row == (settings.readerLayout == .paginated ? 4 : 2)
            || row == (settings.readerLayout == .paginated ? 5 : 3)
    }

private func handleFontSelection(row: Int) {
    guard row == 0 else { return }
    navigationController?.pushViewController(
        ReaderFontChoiceController(settings: settings) { [weak self] in self?.refresh() }, animated: true)
}

    private func handleLayoutSelection(row: Int) {
        let paginated = settings.readerLayout == .paginated
        if row == 0 {
            presentChoice(
                title: L10n.string("readerSettings.mode"),
                options: ReaderLayout.allCases.map(\.displayName),
                selectedIndex: ReaderLayout.allCases.firstIndex(of: settings.readerLayout) ?? 0
            ) { [weak self] index in
                self?.settings.readerLayout = ReaderLayout.allCases[index]
                self?.refresh()
            }
            return
        }
        if isPDF, row == 1 {
            settings.readerShowPageNumbers.toggle()
            refresh()
            return
        }
        if paginated && row == 1 {
            presentChoice(
                title: L10n.string("readerSettings.pageTurnStyle"),
                options: PageTurnStyle.allCases.map(\.displayName),
                selectedIndex: PageTurnStyle.allCases.firstIndex(of: settings.pageTurnStyle) ?? 0
            ) { [weak self] index in
                self?.settings.pageTurnStyle = PageTurnStyle.allCases[index]
                self?.refresh()
            }
            return
        }
        if paginated && row == 2 {
            settings.readerShowPageNumbers.toggle()
            refresh()
            return
        }
        let alignmentRow = paginated ? 3 : 1
        if row == alignmentRow {
            presentChoice(
                title: L10n.string("readerSettings.alignment"),
                options: ReaderTextAlignment.allCases.map(\.displayName),
                selectedIndex: ReaderTextAlignment.allCases.firstIndex(of: settings.readerTextAlignment) ?? 0
            ) { [weak self] index in
                self?.settings.readerTextAlignment = ReaderTextAlignment.allCases[index]
                self?.refresh()
            }
        }
    }

    private func presentChoice(
        title: String,
        options: [String],
        selectedIndex: Int,
        onSelect: @escaping (Int) -> Void
    ) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for (index, option) in options.enumerated() {
            let suffix = index == selectedIndex ? " ✓" : ""
            alert.addAction(UIAlertAction(title: option + suffix, style: .default) { _ in onSelect(index) })
        }
        alert.addAction(UIAlertAction(title: L10n.string("library.cancel"), style: .cancel))
        if let popover = alert.popoverPresentationController,
           let selected = tableView.indexPathForSelectedRow {
            popover.sourceView = tableView
            popover.sourceRect = tableView.rectForRow(at: selected)
        }
        present(alert, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    @objc
    private func doneTapped() {
        dismiss(animated: true, completion: onDismiss)
    }
}
#endif
