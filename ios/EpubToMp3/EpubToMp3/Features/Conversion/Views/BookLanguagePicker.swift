import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
enum BookLanguagePicker {
    static var tags: [String] {
        let codes: [String]
        if #available(iOS 16, macOS 13, *) { codes = Locale.LanguageCode.isoLanguageCodes.map(\.identifier) }
        else { codes = Locale.isoLanguageCodes }
        let identifiers = codes.filter { $0.count == 2 }
            + ["pt-BR", "pt-PT", "en-US", "en-GB", "es-ES", "es-MX"]
        return Set(identifiers).sorted { title($0).localizedStandardCompare(title($1)) == .orderedAscending }
    }
    static func title(_ tag: String) -> String { Locale.current.localizedString(forIdentifier: tag) ?? tag }

    static func choose(allowsAutomatic: Bool, selectedLanguage: String? = nil, detected: String? = nil,
                       orderedTags: [String]? = nil, isCurrent: @escaping () -> Bool) async -> String? {
        let tags = orderedTags ?? self.tags
        let help = L10n.string(allowsAutomatic ? "language.correctionHelp" : "language.inconclusive")
        let explanation = [detected, help].compactMap { $0 }.joined(separator: "\n\n")
        guard !Task.isCancelled, isCurrent() else { return nil }
        #if os(iOS)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var presenter = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let presented = presenter?.presentedViewController { presenter = presented }
        guard let presenter else { return nil }
        let result = await withCheckedContinuation { continuation in
            let chooser = BookLanguageListController(allowsAutomatic: allowsAutomatic, selectedLanguage: selectedLanguage,
                tags: tags, detected: detected, help: help) { continuation.resume(returning: $0) }
            let navigation = UINavigationController(rootViewController: chooser)
            presenter.present(navigation, animated: true)
            navigation.presentationController?.delegate = chooser
        }
        #elseif os(macOS)
        let (alert, popup, choices) = makeMacAlert(allowsAutomatic: allowsAutomatic, selectedLanguage: selectedLanguage,
                                                   explanation: explanation, tags: tags)
        let observer = BookLanguagePopupObserver { index in alert.buttons[0].isEnabled = choices[index] != nil }
        popup.target = observer
        popup.action = #selector(BookLanguagePopupObserver.changed(_:))
        let response = withExtendedLifetime(observer) { alert.runModal() }
        let result: String? = response == .alertFirstButtonReturn ? choices[popup.indexOfSelectedItem] : nil
        #else
        let result: String? = nil
        #endif
        guard !Task.isCancelled, isCurrent() else { return nil }
        return result
    }

    #if os(macOS)
    /// The macOS sheet, built apart from `runModal` so its visual evidence can be rendered.
    static func makeMacAlert(allowsAutomatic: Bool, selectedLanguage: String?, explanation: String,
                             tags: [String]) -> (NSAlert, NSPopUpButton, [String?]) {
        let alert = NSAlert()
        alert.messageText = L10n.string("language.chooseTitle")
        alert.informativeText = explanation
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        let choices: [String?] = (!allowsAutomatic && selectedLanguage == nil ? [nil] : [])
            + ((allowsAutomatic ? [""] : []) + tags).map(Optional.some)
        for tag in choices {
            popup.addItem(withTitle: tag.map { $0.isEmpty ? L10n.string("language.automatic") : title($0) }
                ?? L10n.string("language.choosePrompt"))
        }
        if let index = choices.firstIndex(where: { $0 == (selectedLanguage ?? (allowsAutomatic ? "" : nil)) }) {
            popup.selectItem(at: index)
        }
        popup.setAccessibilityLabel(alert.messageText)
        alert.accessoryView = popup
        alert.addButton(withTitle: L10n.string("common.save"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        alert.buttons[0].isEnabled = choices[popup.indexOfSelectedItem] != nil
        return (alert, popup, choices)
    }
    #endif

    /// `analysis` is given for a whole-book choice: the sheet then says what was detected.
    static func edit(bookID: String, passage: PassageLanguageCorrection? = nil,
                     analysis: (() async -> BookLanguageAnalysis?)? = nil,
                     isCurrent: @escaping () -> Bool) async {
        do {
            let store = BookLanguageCorrections()
            let decision = try store.decision(bookID: bookID)
            let selected = passage.flatMap { scope in
                decision.passages.last { $0.chapterIndex == scope.chapterIndex && $0.start <= scope.start && $0.end >= scope.end }?.language
            } ?? decision.bookLanguage
            let detected = await analysis?().flatMap { BookLanguageSheetSummary(analysis: $0) }?.text
            let catalog = (try? await SpeechModelLibraryClient.shared.catalogLanguages()) ?? []
            guard let language = await choose(allowsAutomatic: true, selectedLanguage: selected, detected: detected,
                orderedTags: BookLanguageSheetSummary.ordered(tags, catalog: catalog), isCurrent: isCurrent) else { return }
            try store.set(language, bookID: bookID, passage: passage)
        } catch { _ = AppErrorReporter.message(error, context: "Save book language correction") }
    }

    static func recover(_ error: Error, bookID: String, isCurrent: @escaping () -> Bool) async -> Bool {
        guard let context = BookLanguageUncertain.decode(error),
              let language = await choose(allowsAutomatic: false, isCurrent: isCurrent) else { return false }
        do {
            try BookLanguageCorrections().set(language, bookID: bookID, passage: context.passage(language: language))
            return isCurrent()
        } catch {
            _ = AppErrorReporter.message(error, context: "Save book language correction")
            return false
        }
    }
}

#if os(iOS)
@MainActor
private final class BookLanguageListController: UITableViewController, UISearchResultsUpdating, UIAdaptivePresentationControllerDelegate {
    private let allowsAutomatic: Bool
    private let selectedLanguage: String?
    private var completion: ((String?) -> Void)?
    private var choices: [String] = []
    private let tags: [String]
    private let detected: String?
    private let help: String
    init(allowsAutomatic: Bool, selectedLanguage: String?, tags: [String], detected: String?, help: String,
         completion: @escaping (String?) -> Void) {
        self.tags = tags
        self.detected = detected
        self.help = help
        self.allowsAutomatic = allowsAutomatic
        self.selectedLanguage = selectedLanguage
        self.completion = completion
        super.init(style: .insetGrouped)
        title = L10n.string("language.chooseTitle")
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        choices = (allowsAutomatic ? [""] : []) + tags
        tableView.accessibilityIdentifier = "language.choices"
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        help
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { detected }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { choices.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Language") ?? UITableViewCell(style: .default, reuseIdentifier: "Language")
        var content = cell.defaultContentConfiguration()
        let tag = choices[indexPath.row]
        content.text = tag.isEmpty ? L10n.string("language.automatic") : BookLanguagePicker.title(tag)
        cell.contentConfiguration = content
        cell.accessoryType = tag == (selectedLanguage ?? "") ? .checkmark : .none
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { finish(choices[indexPath.row]) }
    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text ?? ""
        choices = ((allowsAutomatic ? [""] : []) + tags).filter {
            query.isEmpty || BookLanguagePicker.title($0).localizedCaseInsensitiveContains(query) || $0.localizedCaseInsensitiveContains(query)
        }
        tableView.reloadData()
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { resolve(nil) }
    @objc private func cancel() { finish(nil) }
    private func finish(_ language: String?) { dismiss(animated: true) { [self] in resolve(language) } }
    private func resolve(_ language: String?) { let callback = completion; completion = nil; callback?(language) }
}
#endif

#if os(macOS)
@MainActor
private final class BookLanguagePopupObserver: NSObject {
    private let onChange: (Int) -> Void
    init(onChange: @escaping (Int) -> Void) { self.onChange = onChange }
    @objc func changed(_ sender: NSPopUpButton) { onChange(sender.indexOfSelectedItem) }
}
#endif
