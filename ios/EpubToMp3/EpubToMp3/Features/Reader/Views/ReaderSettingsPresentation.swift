#if os(iOS)
import Combine
import UIKit

@MainActor
final class ReaderSettingsPresentation {
    private let document: ReaderBookDocument
    private let composition: ReaderViewComposition
    private let settings: AppSettings
    private let textPresentation: ReaderTextPresentation
    private let readingPosition: ReaderReadingPosition
    private let isLoading: () -> Bool
    private let applyInterfaceStyle: (UIUserInterfaceStyle) -> Void
    private let present: (UIViewController) -> Void
    private let refreshProbe: () -> Void
    private var settingsUpdateWorkItem: DispatchWorkItem?
    private var settingsCancellable: AnyCancellable?

    init(document: ReaderBookDocument, composition: ReaderViewComposition, settings: AppSettings,
         textPresentation: ReaderTextPresentation, readingPosition: ReaderReadingPosition,
         isLoading: @escaping () -> Bool, applyInterfaceStyle: @escaping (UIUserInterfaceStyle) -> Void,
         present: @escaping (UIViewController) -> Void, refreshProbe: @escaping () -> Void) {
        self.document = document
        self.composition = composition
        self.settings = settings
        self.textPresentation = textPresentation
        self.readingPosition = readingPosition
        self.isLoading = isLoading
        self.applyInterfaceStyle = applyInterfaceStyle
        self.present = present
        self.refreshProbe = refreshProbe
    }

    func observe() {
        settingsCancellable = settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleReaderSettingsUpdate() }
    }

    /// Reader typography/theme/layout controls, presented as a floating
    /// modal sheet (mirrors `presentTOC()` / `showFootnotes()`).
    func presentReaderSettings() {
        let controller = ReaderSettingsScreenController(settings: settings)
        controller.onChange = { [weak self] in
            self?.scheduleReaderSettingsUpdate()
        }
        controller.onDismiss = { [weak self] in
            self?.refreshProbe()
        }
        present(UINavigationController(rootViewController: controller))
    }

    func scheduleReaderSettingsUpdate() {
        guard !isLoading(), document.fulltext != nil || document.activePreparedChapter != nil else {
            applyReaderColors()
            return
        }
        settingsUpdateWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.applyReaderSettingsImmediately()
        }
        settingsUpdateWorkItem = workItem
        // UISlider can emit many values in one drag. Coalesce them to a
        // display-friendly cadence so typography updates stay live without
        // making the control itself lose its gesture.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50), execute: workItem)
    }

    private func applyReaderSettingsImmediately() {
        let readingAnchor = readingPosition.captureReadingAnchor()
        readingPosition.forgetViewportOffsets()
        // Typography and margins can make a formerly oversized protected
        // fragment fit again. Re-evaluate against the final new viewport.
        textPresentation.forcesScrollingForOversizedFragment = false
        let nextTextSettings = ReaderTextSettings(settings: settings)
        let needsTextRerender = textPresentation.lastRenderedTextSettings != nextTextSettings
        let preservesRawOffset = textPresentation.lastRenderedTextSettings?.hasSameGeometry(as: nextTextSettings) == true
            && textPresentation.lastRenderedGeometry?.margin == settings.readerMargin
            && textPresentation.lastRenderedGeometry?.layout == settings.readerLayout
            && textPresentation.lastRenderedGeometry?.showsNumbers == settings.readerShowPageNumbers
        applyReaderColors()
        textPresentation.applyReaderLayoutMode()
        textPresentation.applyReaderMargins()
        composition.view.setNeedsLayout()
        composition.view.layoutIfNeeded()
        if needsTextRerender {
            textPresentation.showChapter(document.selectedChapter)
        } else {
            textPresentation.updateTextHeightForCurrentLayout()
        }
        composition.view.layoutIfNeeded()
        readingPosition.restoreReadingAnchor(readingAnchor, preservingViewportOffset: preservesRawOffset)
        textPresentation.lastRenderedGeometry = (settings.readerMargin, settings.readerLayout, settings.readerShowPageNumbers)
        textPresentation.updatePageIndicator()
        readingPosition.persistReadingProgress()
    }

    func applyReaderColors() {
        let style: UIUserInterfaceStyle
        switch settings.readerPreferredColorScheme {
        case .dark: style = .dark
        case .light: style = .light
        case nil: style = .unspecified
        }
        applyInterfaceStyle(style)
        let colors = settings.readerColors
        composition.view.backgroundColor = colors.background
        composition.view.tintColor = colors.link
        composition.scrollView.backgroundColor = colors.background
        composition.textView.backgroundColor = colors.background
        composition.textView.linkTextAttributes = settings.readerTheme != .light || settings.readerOverrideColours
            ? [.foregroundColor: colors.link, .underlineStyle: NSUnderlineStyle.single.rawValue]
            : [:]
        composition.loadingContainer.backgroundColor = colors.background
        composition.loadingStatusLabel.textColor = colors.foreground.withAlphaComponent(0.75)
        composition.pageIndicator.textColor = colors.foreground.withAlphaComponent(0.7)
        composition.pageOverflowGuard.backgroundColor = colors.background
        composition.pageUnderflowGuard.backgroundColor = colors.background
    }

}
#endif
