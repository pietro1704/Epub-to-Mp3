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
#if os(iOS)
struct SettingsView: View {
    var body: some View {
        EmptyView()
    }

    static var platformMinimumLabel: String {
        let info = Bundle.main.infoDictionary
        if let version = info?["MinimumOSVersion"] as? String, !version.isEmpty {
            return "iOS \(version)+"
        }
        return "iOS 15.0+"
    }
}
#else
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var sidecar: SidecarManager
    @State private var showClearCacheConfirm = false
    @State private var clearCacheDone = false
    @State private var showClearAllDownloadsConfirm = false
    @State private var storageUsage = StorageUsageScanner.current()

    var body: some View {
        Group {
            if #available(macOS 13, *) {
                Form {
                    embeddedServerSection
                    backendSection
                    readerSection
                    storageSection
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
                    storageSection
                    advancedSection
                    cloudSection
                    aboutSection
                }
            }
        }
        .navigationTitle(L10n.string("settings.title"))
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

    @ViewBuilder
    private var backendSection: some View {
        Section {
            // ViewThatFits: at XXXL Dynamic Type the Label and text field
            // stack vertically so the URL field is not clipped.
            CompatViewThatFitsHV {
                HStack {
                    Label(L10n.string("settings.url"), systemImage: "network")
                    Spacer()
                    TextField("http://localhost:8000",
                              text: $settings.backendURL)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                }
            } vertical: {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.string("settings.url"), systemImage: "network")
                    TextField("http://localhost:8000",
                              text: $settings.backendURL)
                        .autocorrectionDisabled()
                }
            }
            if self.settings.resolvedBaseURL == nil && settings.remoteBackendControlsEnabled {
                Label(L10n.string("settings.urlNotValid"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        } header: {
            Text(L10n.string("settings.remoteBackend"))
        } footer: {
            Text(L10n.string("settings.remoteBackendFooterMac"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .disabled(!settings.remoteBackendControlsEnabled)
        .opacity(settings.remoteBackendControlsEnabled ? 1 : 0.45)
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

    private var storageSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(L10n.string("settings.storageUsage"), systemImage: "internaldrive")
                    Spacer()
                    Text("\(formatBytes(storageUsage.totalBytes)) / \(formatBytes(storageUsage.budgetBytes))")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: storageUsage.budgetFraction)
                    .tint(storageUsage.budgetFraction >= 0.9 ? .red : .accentColor)
                    .accessibilityLabel(L10n.string("settings.storageUsage"))
                    .accessibilityValue("\(Int(storageUsage.budgetFraction * 100))%")
                storageRow("settings.offlineAudio", bytes: storageUsage.offlineAudioBytes)
                storageRow("settings.ttsCache", bytes: storageUsage.ttsCacheBytes)
                storageRow("settings.storageTotal", bytes: storageUsage.totalBytes)
            }
            Button {
                refreshStorageUsage()
            } label: {
                Label(L10n.string("settings.refreshStorage"), systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                showClearAllDownloadsConfirm = true
            } label: {
                Label(L10n.string("settings.clearAllDownloads"), systemImage: "trash")
            }
            .confirmationDialog(
                L10n.string("settings.clearAllDownloadsConfirmTitle"),
                isPresented: $showClearAllDownloadsConfirm,
                titleVisibility: .visible
            ) {
                Button(L10n.string("settings.clearCacheConfirmButton"), role: .destructive) {
                    clearAllDownloads()
                }
                Button(L10n.string("library.cancel"), role: .cancel) {}
            } message: {
                Text(L10n.string("settings.clearAllDownloadsConfirmMessage"))
            }
        } header: {
            Text(L10n.string("settings.storage"))
        } footer: {
            Text(L10n.string("settings.storageFooter"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onAppear { refreshStorageUsage() }
    }

    private func storageRow(_ key: String, bytes: Int64) -> some View {
        HStack {
            Text(L10n.string(key))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Text(formatBytes(bytes))
                .font(.footnote.monospacedDigit())
        }
    }

    private func refreshStorageUsage() {
        storageUsage = StorageUsageScanner.current(budgetBytes: settings.offlineCacheBudgetBytes)
    }

    private func clearAllDownloads() {
        Task { await DownloadManager.shared.cancelAll() }
        StorageUsageScanner.clearAllDownloads()
        for var book in library.books where book.cachedOffline {
            book.cachedOffline = false
            library.update(book)
        }
        refreshStorageUsage()
        clearCacheDone = true
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    @ViewBuilder
    private var advancedSection: some View {
        Section {
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
            Button(role: .destructive) {
                showClearCacheConfirm = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.string("settings.clearCache"))
                        Text(L10n.string("settings.clearCacheDescription"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
            }
            .confirmationDialog(
                L10n.string("settings.clearCacheConfirmTitle"),
                isPresented: $showClearCacheConfirm,
                titleVisibility: .visible
            ) {
                Button(L10n.string("settings.clearCacheConfirmButton"), role: .destructive) {
                    clearAllDownloads()
                }
                Button(L10n.string("library.cancel"), role: .cancel) {}
            } message: {
                Text(L10n.string("settings.clearCacheConfirmMessage"))
            }
            .alert(L10n.string("settings.clearCacheDone"), isPresented: $clearCacheDone) {
                Button(L10n.string("library.ok")) { clearCacheDone = false }
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

    /// Dynamic "iOS 15.0+" / "macOS 12.0+" label, sourced from the
    /// bundle's deployment-target Info.plist keys. Falls back to a
    /// static label when the keys are missing (e.g. SPM preview builds).
    static var platformMinimumLabel: String {
        let info = Bundle.main.infoDictionary
        if let version = info?["LSMinimumSystemVersion"] as? String, !version.isEmpty {
            return "macOS \(version)+"
        }
        return "macOS 12.0+"
    }
}
#endif

#if DEBUG && !os(iOS)
#Preview("Settings") {
    CompatNavigationStack { SettingsView() }
        .environmentObject(AppSettings())
        .environmentObject(LibraryStore())
        .environmentObject(AudioPlayer())
        .environmentObject(PlaybackClock())
        #if os(macOS)
        .environmentObject(SidecarManager())
        #endif
}
#endif
