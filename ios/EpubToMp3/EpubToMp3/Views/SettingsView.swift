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
    @Environment(AppSettings.self) private var settings
    #if os(macOS)
    @Environment(SidecarManager.self) private var sidecar
    #endif

    var body: some View {
        @Bindable var bindable = settings
        return Group {
            #if os(macOS)
            Form {
                embeddedServerSection(bindable: bindable)
                backendSection(bindable: bindable)
                readerSection(bindable: bindable)
                advancedSection
                aboutSection
            }
            .formStyle(.grouped)
            #else
            Form {
                backendSection(bindable: bindable)
                readerSection(bindable: bindable)
                advancedSection
                aboutSection
            }
            #endif
        }
        .navigationTitle("Settings")
    }

    // MARK: - Sections

    #if os(macOS)
    @ViewBuilder
    private func embeddedServerSection(bindable: AppSettings) -> some View {
        Section {
            Toggle(isOn: Bindable(bindable).useEmbeddedSidecar) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use embedded server")
                        Text("Runs a private Python instance on a free local port. Recommended.")
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
            Text("Embedded server")
        } footer: {
            Text("When the embedded server is on, the app is fully self-contained and works offline. Turn off only if you want to point at a remote backend.")
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
    }

    private var sidecarStatusLabel: String {
        switch sidecar.state {
        case .idle:                 return "Idle"
        case .starting:             return "Starting…"
        case .running:              return "Running"
        case .failed(let err):      return "Failed — \(err.prefix(120))"
        case .unsupported:          return "Unsupported on this platform"
        }
    }
    #endif

    @ViewBuilder
    private func backendSection(bindable: AppSettings) -> some View {
        Section {
            HStack {
                Label("URL", systemImage: "network")
                Spacer()
                let field = TextField("http://localhost:8000",
                                      text: Bindable(bindable).backendURL)
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
            if self.settings.resolvedBaseURL == nil {
                Label("URL is not valid", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        } header: {
            Text("Remote backend")
        } footer: {
            #if os(macOS)
            Text("Used when the embedded server is off. Common targets: a `mise run web` instance on this machine, or a Hugging Face Space URL.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            #else
            Text("Examples: a `mise run web` instance on your laptop, or a Hugging Face Space URL.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            #endif
        }
    }

    @ViewBuilder
    private func readerSection(bindable: AppSettings) -> some View {
        Section {
            HStack {
                Label("Font size", systemImage: "textformat.size")
                Spacer()
                Stepper(value: Bindable(bindable).readerFontSize, in: 0...4) {
                    Text("\(self.settings.readerFontSize + 1) of 5")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .labelsHidden()
            }
            Picker(selection: Bindable(bindable).readerFontFamily) {
                ForEach(ReaderFontFamily.allCases) { f in
                    Text(f.displayName).tag(f)
                }
            } label: {
                Label("Font", systemImage: "textformat")
            }
            Picker(selection: Bindable(bindable).readerTheme) {
                ForEach(ReaderTheme.allCases) { t in
                    Text(t.displayName).tag(t)
                }
            } label: {
                Label("Theme", systemImage: "paintpalette")
            }
            Toggle(isOn: Bindable(bindable).readerAutoScroll) {
                Label("Auto-scroll", systemImage: "arrow.down.to.line")
            }
        } header: {
            Text("Reader")
        } footer: {
            Text("These preferences apply to every book in your library.")
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
                        Text("Manual conversion")
                        Text("Customise engine, voice, language and chapter range")
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
                        Text("Recent jobs")
                        Text("Conversion history and live progress")
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
                        Text("Telemetry")
                        Text("Per-engine speed and quality metrics")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "speedometer")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Advanced")
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section {
            LabeledContent {
                Text("com.pietrocode.epubtomp3")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } label: {
                Label("Bundle identifier", systemImage: "shippingbox")
            }
            LabeledContent {
                #if os(iOS)
                Text("iOS 17.0+")
                #elseif os(macOS)
                Text("macOS 14.0+")
                #else
                Text("—")
                #endif
            } label: {
                Label("Platform", systemImage: "macbook.and.iphone")
            }
            Link(destination: URL(string: "https://github.com/pietro1704/Epub-to-Mp3")!) {
                Label("Project on GitHub", systemImage: "arrow.up.right.square")
            }
        } header: {
            Text("About")
        }
    }
}

#Preview("Settings") {
    NavigationStack { SettingsView() }
        .environment(AppSettings())
        .environment(LibraryStore())
        #if os(macOS)
        .environment(SidecarManager())
        #endif
}
