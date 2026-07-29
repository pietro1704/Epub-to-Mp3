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
    }

    private let settings: AppSettings

    /// Fired at the end of every `refresh()` — i.e. right after any setting
    /// changes — so the reader behind this sheet can re-render immediately.
    var onChange: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
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
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.string("readerSettings.done"),
            style: .done,
            target: self,
            action: #selector(doneTapped)
        )
    }

    func refresh() {
        guard isViewLoaded else { return }
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
            return 2
        case .layout:
            return settings.readerLayout == .paginated ? 6 : 4
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .theme: return L10n.string("readerSettings.theme")
        case .font: return L10n.string("readerSettings.font")
        case .layout: return L10n.string("readerSettings.layout")
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        // Cells are reused across sections. Remove any slider installed by
        // the previous row before configuring the current row.
        cell.contentView.subviews
            .filter { $0 is UISlider }
            .forEach { $0.removeFromSuperview() }
        var content = cell.defaultContentConfiguration()
        cell.accessoryType = .none
        guard let section = Section(rawValue: indexPath.section) else { return cell }

        switch section {
        case .theme:
            let themes = ReaderTheme.allCases.filter { $0 != .custom }
            let theme = themes[indexPath.row]
            content.text = theme.displayName
            content.image = Self.themePreviewImage(for: theme)
            cell.accessoryType = settings.readerTheme == theme ? .checkmark : .none
        case .font:
            if indexPath.row == 0 {
                content.text = L10n.string("readerSettings.family")
                content.secondaryText = settings.readerFontFamily.displayName
                cell.accessoryType = .disclosureIndicator
            } else {
                content.text = L10n.string("readerSettings.size")
                content.secondaryText = "\(Int(settings.readerPointSize))pt"
                configureSlider(in: cell, value: Float(settings.readerFontSize), min: 0, max: 4, step: 1, identifier: "reader.settings.fontSize")
                cell.accessoryType = .none
            }
        case .layout:
            layoutCellContent(&content, row: indexPath.row)
            cell.accessoryType = .disclosureIndicator
            if isSliderLayoutRow(indexPath.row) {
                let value: Double
                let range: (Double, Double)
                if indexPath.row == (settings.readerLayout == .paginated ? 4 : 2) {
                    value = settings.readerLineSpacing
                    range = (0, 16)
                } else {
                    value = settings.readerMargin
                    range = (12, 80)
                }
                configureSlider(in: cell, value: Float(value), min: Float(range.0), max: Float(range.1), step: indexPath.row == (settings.readerLayout == .paginated ? 4 : 2) ? 2 : 4, identifier: indexPath.row == (settings.readerLayout == .paginated ? 4 : 2) ? "reader.settings.lineSpacing" : "reader.settings.margin")
                cell.accessoryType = .none
            }
            if isToggleLayoutRow(indexPath.row) {
                cell.accessoryType = settings.readerShowPageNumbers ? .checkmark : .none
            }
        }

        cell.contentConfiguration = content
        cell.accessibilityLabel = content.text
        cell.accessibilityValue = content.secondaryText ?? (section == .theme ? themeAccessibilityValue(indexPath.row) : nil)
        cell.accessibilityHint = isToggleLayoutRow(indexPath.row)
            ? L10n.string("readerSettings.toggleHint")
            : L10n.string("readerSettings.chooseOptionHint")
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
        }
    }

    private func layoutCellContent(_ content: inout UIListContentConfiguration, row: Int) {
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
        settings.readerLayout == .paginated && row == 2
    }

    private func isSliderLayoutRow(_ row: Int) -> Bool {
        row == (settings.readerLayout == .paginated ? 4 : 2)
            || row == (settings.readerLayout == .paginated ? 5 : 3)
    }

    private func configureSlider(in cell: UITableViewCell, value: Float, min: Float, max: Float, step: Float, identifier: String) {
        cell.contentView.subviews
            .filter { $0 is UISlider }
            .forEach { $0.removeFromSuperview() }
        let slider = UISlider()
        slider.minimumValue = min
        slider.maximumValue = max
        slider.value = value
        let tint = settings.readerTheme.previewColors.foreground
        slider.minimumTrackTintColor = tint
        slider.maximumTrackTintColor = tint.withAlphaComponent(0.3)
        slider.thumbTintColor = tint
        slider.accessibilityIdentifier = identifier
        slider.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
        slider.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(slider)
        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor, constant: 116),
            slider.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            slider.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 42),
            slider.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8)
        ])
        slider.accessibilityValue = "\(Int(value))"
        slider.tag = Int(step * 1000)
    }

    @objc private func sliderChanged(_ slider: UISlider) {
        let step = Float(max(1, slider.tag)) / 1000
        let snapped = round(slider.value / Float(step)) * Float(step)
        slider.setValue(snapped, animated: false)
        slider.accessibilityValue = "\(Int(snapped))"
        switch slider.accessibilityIdentifier {
        case "reader.settings.fontSize": settings.readerFontSize = Int(snapped)
        case "reader.settings.lineSpacing": settings.readerLineSpacing = Double(snapped)
        case "reader.settings.margin": settings.readerMargin = Double(snapped)
        default: break
        }
        refresh()
    }

    private func handleFontSelection(row: Int) {
        if row == 0 {
            presentChoice(
                title: L10n.string("readerSettings.family"),
                options: ReaderFontFamily.allCases.map { "\($0.displayName) — Aa Bb Cc" },
                selectedIndex: ReaderFontFamily.allCases.firstIndex(of: settings.readerFontFamily) ?? 0
            ) { [weak self] index in
                self?.settings.readerFontFamily = ReaderFontFamily.allCases[index]
                self?.settings.readerOverrideFontFamily = true
                self?.refresh()
            }
        } else {
            let sizes = Array(0...4)
            presentChoice(
                title: L10n.string("readerSettings.size"),
                options: sizes.map { "\((Int(AppSettings.pointSize(for: $0))))pt" },
                selectedIndex: settings.readerFontSize
            ) { [weak self] index in
                self?.settings.readerFontSize = index
                self?.refresh()
            }
        }
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
        let spacingRow = paginated ? 4 : 2
        if row == alignmentRow {
            presentChoice(
                title: L10n.string("readerSettings.alignment"),
                options: ReaderTextAlignment.allCases.map(\.displayName),
                selectedIndex: ReaderTextAlignment.allCases.firstIndex(of: settings.readerTextAlignment) ?? 0
            ) { [weak self] index in
                self?.settings.readerTextAlignment = ReaderTextAlignment.allCases[index]
                self?.refresh()
            }
        } else if row == spacingRow {
            let values = Array(stride(from: 0, through: 16, by: 2))
            presentChoice(
                title: L10n.string("readerSettings.lineSpacing"),
                options: values.map { String($0) },
                selectedIndex: values.firstIndex(of: Int(settings.readerLineSpacing)) ?? 0
            ) { [weak self] index in
                self?.settings.readerLineSpacing = Double(values[index])
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
        dismiss(animated: true)
    }
}
#endif
