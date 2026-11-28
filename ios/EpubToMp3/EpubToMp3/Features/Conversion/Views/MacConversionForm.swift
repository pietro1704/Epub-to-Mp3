#if os(macOS)
import AppKit

/// AppKit controls for the shared manual-conversion model.
@MainActor
final class MacConversionForm: NSView {
    let fileLabel = NSTextField(wrappingLabelWithString: "")
    let pickFile = NSButton()
    let pronunciation = NSButton()
    let engine = NSPopUpButton()
    let secondary = NSButton(checkboxWithTitle: L10n.string("convert.allowSecondary"), target: nil, action: nil)
    let voice = NSTextField()
    let language = NSTextField()
    let chapters = NSTextField()
    let silenceTrim = NSPopUpButton()
    let clearCache = NSButton(checkboxWithTitle: L10n.string("convert.clearCache"), target: nil, action: nil)
    let forceReprocess = NSButton(checkboxWithTitle: L10n.string("convert.forceReprocess"), target: nil, action: nil)
    let maxPerformance = NSButton(checkboxWithTitle: L10n.string("convert.maxPerformance"), target: nil, action: nil)
    let submit = NSButton()
    let cancel = NSButton()
    let status = NSTextField(wrappingLabelWithString: "")
    let failure = NSTextField(wrappingLabelWithString: "")
    let result = NSTextField(wrappingLabelWithString: "")
    let revealResult = NSButton()
    let history = NSButton()

    init() {
        super.init(frame: .zero)
        setAccessibilityIdentifier("convert.screen")
        let title = NSTextField(labelWithString: L10n.string("convert.title"))
        title.font = .boldSystemFont(ofSize: 22)
        configure(pickFile, key: "convert.pickFile", identifier: "convert.pickFile")
        configure(pronunciation, key: "pronunciation.title", identifier: "convert.pronunciation")
        configure(submit, key: "convert.startConversion", identifier: "convert.submit")
        configure(cancel, key: "convert.cancel", identifier: "convert.cancel")
        configure(revealResult, key: "convert.openResult", identifier: "convert.openResult")
        let historyTitle = L10n.string("jobs.title")
        history.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: historyTitle)
        history.imagePosition = .imageOnly
        history.bezelStyle = .texturedRounded
        history.toolTip = historyTitle
        history.setAccessibilityLabel(historyTitle)
        history.setAccessibilityIdentifier("convert.history")
        let header = NSStackView(views: [title, NSView(), history])
        header.orientation = .horizontal
        engine.addItems(withTitles: [L10n.string("convert.usePreferences")]
            + TtsSelection.selectableEngines.map { TtsSelection.displayName(forEngine: $0) ?? $0 })
        engine.setAccessibilityIdentifier("convert.tts.primary")
        engine.setAccessibilityLabel(L10n.string("settings.audioEngineChoice"))
        secondary.setAccessibilityIdentifier("convert.tts.useSecondary")
        configure(voice, key: "convert.voiceOptional", identifier: "convert.voice")
        configure(language, key: "convert.languageOptional", identifier: "convert.language")
        configure(chapters, key: "convert.chapterRangeOptional", identifier: "convert.chapters")
        chapters.placeholderString = L10n.string("convert.chapterRangeHelp")
        silenceTrim.addItems(withTitles: SilenceTrim.allCases.map(\.title))
        silenceTrim.setAccessibilityIdentifier("convert.silenceTrim")
        silenceTrim.setAccessibilityLabel(L10n.string("silenceTrim.title"))
        let silenceTrimDescription = NSTextField(wrappingLabelWithString: L10n.string("silenceTrim.description"))
        silenceTrimDescription.font = .preferredFont(forTextStyle: .subheadline)
        silenceTrimDescription.textColor = .readableSecondaryLabel
        clearCache.setAccessibilityIdentifier("convert.clearCache")
        forceReprocess.setAccessibilityIdentifier("convert.forceReprocess")
        maxPerformance.setAccessibilityIdentifier("convert.maxPerformance")
        fileLabel.setAccessibilityIdentifier("convert.selectedFile")
        status.setAccessibilityIdentifier("convert.status")
        failure.setAccessibilityIdentifier("convert.error")
        result.setAccessibilityIdentifier("convert.result")
        failure.textColor = .systemRed
        result.isSelectable = true
        let actions = NSStackView(views: [submit, cancel])
        actions.orientation = .horizontal
        actions.spacing = 12
        let stack = NSStackView(views: [header, fileLabel, pickFile, pronunciation,
            field(L10n.string("settings.audioEngineChoice"), engine), secondary,
            field(L10n.string("convert.voiceOptional"), voice),
            field(L10n.string("convert.languageOptional"), language),
            field(L10n.string("convert.chapterRangeOptional"), chapters),
            field(L10n.string("silenceTrim.title"), silenceTrim), silenceTrimDescription,
            clearCache, forceReprocess, maxPerformance, actions, status, failure, result, revealResult])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        MacScrollableStack.install(stack, in: self)
        for label in [header, fileLabel, silenceTrimDescription, status, failure, result] {
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var editableControls: [NSControl] {
        [pickFile, pronunciation, engine, secondary, voice, language, chapters, silenceTrim,
         clearCache, forceReprocess, maxPerformance]
    }

    private func configure(_ button: NSButton, key: String, identifier: String) {
        button.title = L10n.string(key)
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier(identifier)
    }

    private func configure(_ field: NSTextField, key: String, identifier: String) {
        field.placeholderString = L10n.string(key)
        field.setAccessibilityLabel(L10n.string(key))
        field.setAccessibilityIdentifier(identifier)
    }

    private func field(_ title: String, _ control: NSControl) -> NSView {
        let label = NSTextField(labelWithString: title)
        let row = NSStackView(views: [label, control])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 4
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        return row
    }
}
#endif
