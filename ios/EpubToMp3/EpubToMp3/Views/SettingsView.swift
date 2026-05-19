import SwiftUI

/// Settings root. Apple HIG: every settings screen is a `Form` with
/// short, scannable sections, each preceded by a small uppercase
/// header that names the *intent* (not the technology). Rows have
/// SF Symbols on the leading edge, descriptive secondary text on
/// the trailing edge, and footnote captions for anything that needs
/// an explanation.
///
/// macOS prefers `.formStyle(.grouped)` (the modern System Settings
/// look — translucent panels, generous spacing). iOS / iPadOS keep
/// the default inset-grouped style.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    #if os(macOS)
    @EnvironmentObject private var sidecar: SidecarManager
    #endif

    var body: some View {
        #if os(macOS)
        Group {
            if #available(macOS 13, *) {
                Form {
                    embeddedServerSection
                    backendSection
                    readerSection
                    advancedSection
                    cloudSection
                    aboutSection
                }
                .formStyle(.grouped)
            } else {
                // `.formStyle(.grouped)` is macOS 13+. The default Form
                // chrome on Big Sur looks acceptable; the sections are
                // still scannable.
                Form {
                    embeddedServerSection
                    backendSection
                    readerSection
                    advancedSection
                    cloudSection
                    aboutSection
                }
            }
        }
        .navigationTitle(L10n.string("settings.title"))
        #else
        settingsForm
        #endif
    }

    // MARK: - Sections

    #if os(macOS)
    @ViewBuilder
    private var embeddedServerSection: some View {
        Section {
            Toggle(isOn: $settings.useEmbeddedSidecar) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.string("settings.useEmbeddedServer"))
                        Text(L10n.string("settings.useEmbeddedServerDescription"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "shippingbox.fill")
                        .foregroundStyle(.tint)
                }
            }

            HStack(spacing: 8) {
                statusDot
                Text(sidecarStatusLabel)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if case .running(let url) = sidecar.state {
                    Text(url.host.flatMap { "\($0):\(url.port ?? 0)" } ?? url.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text(L10n.string("settings.embeddedServer"))
        } footer: {
            Text(L10n.string("settings.embeddedServerFooter"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var statusDot: some View {
        let color: Color = {
            switch sidecar.state {
            case .running:     return .green
            case .starting:    return .orange
            case .failed:      return .red
            case .idle, .unsupported: return .gray
            }
        }()
        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(sidecarStatusLabel)
            .accessibilityIdentifier("settings.sidecarStatusDot")
    }

    private var sidecarStatusLabel: String {
        switch sidecar.state {
        case .idle:                 return L10n.string("settings.sidecar.idle")
        case .starting:             return L10n.string("settings.sidecar.starting")
        case .running:              return L10n.string("settings.sidecar.running")
        case .failed(let err):      return L10n.string("settings.sidecar.failed", String(err.prefix(120)))
        case .unsupported:          return L10n.string("settings.sidecar.unsupported")
        }
    }
    #endif

    /// iOS-only toggle that exposes ``AppSettings.useEmbeddedRuntime``.
    /// On macOS the equivalent control lives in ``embeddedServerSection``
    /// (the sidecar toggle). Hiding it on macOS keeps the Settings UI
    /// from duplicating the same idea.
    @ViewBuilder
    private var embeddedRuntimeSection: some View {
        Section {
            Toggle(isOn: $settings.useEmbeddedRuntime) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.string("settings.useBuiltInEngine"))
                        Text(L10n.string("settings.useBuiltInEngineDescription"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "iphone.gen3")
                        .foregroundStyle(.tint)
                }
            }
        } header: {
            Text(L10n.string("settings.audioEngine"))
        } footer: {
            Text(L10n.string("settings.audioEngineFooter"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var backendSection: some View {
        Section {
            // ViewThatFits: at XXXL Dynamic Type the Label and text field
            // stack vertically so the URL field is not clipped.
            CompatViewThatFitsHV {
                HStack {
                    Label(L10n.string("settings.url"), systemImage: "network")
                    Spacer()
                    let field = TextField("http://localhost:8000",
                                          text: $settings.backendURL)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                    #if os(iOS)
                    field
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    #else
                    field
                    #endif
                }
            } vertical: {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.string("settings.url"), systemImage: "network")
                    let field = TextField("http://localhost:8000",
                                          text: $settings.backendURL)
                        .autocorrectionDisabled()
                    #if os(iOS)
                    field
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    #else
                    field
                    #endif
                }
            }
            if self.settings.resolvedBaseURL == nil {
                Label(L10n.string("settings.urlNotValid"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        } header: {
            Text(L10n.string("settings.remoteBackend"))
        } footer: {
            #if os(macOS)
            Text(L10n.string("settings.remoteBackendFooterMac"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            #else
            Text(L10n.string("settings.remoteBackendFooterIOS"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            #endif
        }
    }

    @ViewBuilder
    private var readerSection: some View {
        Section {
            // Each Label+Stepper row uses ViewThatFits so at XXXL Dynamic
            // Type the label stacks above the stepper instead of being
            // squeezed off-screen in the trailing HStack.
            CompatViewThatFitsHV {
                HStack {
                    Label(L10n.string("settings.fontSize"), systemImage: "textformat.size")
                    Spacer()
                    Stepper(value: $settings.readerFontSize, in: 0...4) {
                        Text("\(self.settings.readerFontSize + 1) of 5")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .labelsHidden()
                }
            } vertical: {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.string("settings.fontSize"), systemImage: "textformat.size")
                    Stepper(value: $settings.readerFontSize, in: 0...4) {
                        Text("\(self.settings.readerFontSize + 1) of 5")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .labelsHidden()
                }
            }
            Picker(selection: $settings.readerFontFamily) {
                ForEach(ReaderFontFamily.allCases) { f in
                    Text(f.displayName).tag(f)
                }
            } label: {
                Label(L10n.string("settings.font"), systemImage: "textformat")
            }
            Picker(selection: $settings.readerTheme) {
                ForEach(ReaderTheme.allCases) { t in
                    Text(t.displayName).tag(t)
                }
            } label: {
                Label(L10n.string("settings.theme"), systemImage: "paintpalette")
            }
            Picker(selection: $settings.readerLayout) {
                ForEach(ReaderLayout.allCases) { l in
                    Text(l.displayName).tag(l)
                }
            } label: {
                Label(L10n.string("settings.layout"), systemImage: "doc.text")
            }
            CompatViewThatFitsHV {
                HStack {
                    Label(L10n.string("settings.lineSpacing"), systemImage: "arrow.up.and.down.text.horizontal")
                    Spacer()
                    Stepper(value: $settings.readerLineSpacing,
                            in: 0...16, step: 2) {
                        Text("\(Int(self.settings.readerLineSpacing)) pt")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .labelsHidden()
                }
            } vertical: {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.string("settings.lineSpacing"), systemImage: "arrow.up.and.down.text.horizontal")
                    Stepper(value: $settings.readerLineSpacing,
                            in: 0...16, step: 2) {
                        Text("\(Int(self.settings.readerLineSpacing)) pt")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .labelsHidden()
                }
            }
            CompatViewThatFitsHV {
                HStack {
                    Label(L10n.string("settings.margin"), systemImage: "rectangle.compress.vertical")
                    Spacer()
                    Stepper(value: $settings.readerMargin,
                            in: 16...80, step: 4) {
                        Text("\(Int(self.settings.readerMargin)) pt")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .labelsHidden()
                }
            } vertical: {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.string("settings.margin"), systemImage: "rectangle.compress.vertical")
                    Stepper(value: $settings.readerMargin,
                            in: 16...80, step: 4) {
                        Text("\(Int(self.settings.readerMargin)) pt")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .labelsHidden()
                }
            }
            CompatViewThatFitsHV {
                HStack {
                    Label(L10n.string("settings.columnWidth"), systemImage: "rectangle.split.3x1")
                    Spacer()
                    Stepper(value: $settings.readerColumnWidth,
                            in: 420...960, step: 40) {
                        Text("\(Int(self.settings.readerColumnWidth)) pt")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .labelsHidden()
                }
            } vertical: {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.string("settings.columnWidth"), systemImage: "rectangle.split.3x1")
                    Stepper(value: $settings.readerColumnWidth,
                            in: 420...960, step: 40) {
                        Text("\(Int(self.settings.readerColumnWidth)) pt")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .labelsHidden()
                }
            }
            Toggle(isOn: $settings.readerAutoScroll) {
                Label(L10n.string("settings.autoScroll"), systemImage: "arrow.down.to.line")
            }
        } header: {
            Text(L10n.string("settings.reader"))
        } footer: {
            Text(L10n.string("settings.readerFooter"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        Section {
            NavigationLink {
                ConvertView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.string("settings.manualConversion"))
                        Text(L10n.string("settings.manualConversionDescription"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(.purple)
                }
            }
            NavigationLink {
                JobsListView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.string("settings.recentJobs"))
                        Text(L10n.string("settings.recentJobsDescription"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.blue)
                }
            }
            NavigationLink {
                TelemetryView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.string("settings.telemetry"))
                        Text(L10n.string("settings.telemetryDescription"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "speedometer")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text(L10n.string("settings.advanced"))
        }
    }

    @ViewBuilder
    private var cloudSection: some View {
        Section {
            CompatViewThatFitsHV {
                HStack {
                    Label(L10n.string("settings.icloudSync"), systemImage: "icloud")
                    Spacer()
                    Text(L10n.string("settings.comingSoon"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } vertical: {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.string("settings.icloudSync"), systemImage: "icloud")
                    Text(L10n.string("settings.comingSoon"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L10n.string("settings.sync"))
        } footer: {
            Text(L10n.string("settings.syncFooter"))
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section {
            CompatLabeledContent {
                Text(verbatim: "com.pietrocode.epubtomp3")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } label: {
                Label(L10n.string("settings.bundleIdentifier"), systemImage: "shippingbox")
            }
            CompatLabeledContent {
                Text(Self.platformMinimumLabel)
                    .textSelection(.enabled)
            } label: {
                Label(L10n.string("settings.platform"), systemImage: "macbook.and.iphone")
            }
            Link(destination: URL(string: "https://github.com/pietro1704/Epub-to-Mp3")!) {
                Label(L10n.string("settings.projectOnGithub"), systemImage: "arrow.up.right.square")
            }
        } header: {
            Text(L10n.string("settings.about"))
        }
    }

    #if os(iOS)
    /// iOS settings form with extra bottom scroll margin.
    ///
    /// SwiftUI's Form (UITableView) sometimes clips the last section
    /// behind the tab bar when nested inside NavigationStack > TabView,
    /// especially when a `.safeAreaInset` (MiniPlayerBar) is applied
    /// on an ancestor. We add extra bottom inset via `.contentMargins`
    /// (iOS 17+) or a transparent spacer section (iOS 15–16).
    @ViewBuilder
    private var settingsForm: some View {
        if #available(iOS 17, *) {
            Form {
                embeddedRuntimeSection
                backendSection
                readerSection
                advancedSection
                aboutSection
            }
            .contentMargins(.bottom, 88, for: .scrollContent)
            .navigationTitle(L10n.string("settings.title"))
        } else {
            Form {
                embeddedRuntimeSection
                backendSection
                readerSection
                advancedSection
                aboutSection

                // Invisible spacer section — extends the scroll content
                // so the about section clears the tab bar + mini-player.
                Section {
                    Color.clear
                        .frame(height: 80)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle(L10n.string("settings.title"))
        }
    }
    #endif

    /// Dynamic "iOS 15.0+" / "macOS 12.0+" label, sourced from the
    /// bundle's deployment-target Info.plist keys. Falls back to a
    /// static label when the keys are missing (e.g. SPM preview builds).
    static var platformMinimumLabel: String {
        let info = Bundle.main.infoDictionary
        #if os(iOS)
        if let version = info?["MinimumOSVersion"] as? String, !version.isEmpty {
            return "iOS \(version)+"
        }
        return "iOS 15.0+"
        #elseif os(macOS)
        if let version = info?["LSMinimumSystemVersion"] as? String, !version.isEmpty {
            return "macOS \(version)+"
        }
        return "macOS 12.0+"
        #else
        return "—"
        #endif
    }
}

#Preview("Settings") {
    CompatNavigationStack { SettingsView() }
        .environmentObject(AppSettings())
        .environmentObject(LibraryStore())
        #if os(macOS)
        .environmentObject(SidecarManager())
        #endif
}
