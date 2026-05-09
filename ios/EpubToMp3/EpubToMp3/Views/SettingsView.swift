import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    #if os(macOS)
    @Environment(SidecarManager.self) private var sidecar
    #endif

    var body: some View {
        @Bindable var settings = settings

        Form {
            #if os(macOS)
            Section("Embedded server") {
                Toggle("Use embedded Python sidecar",
                       isOn: $settings.useEmbeddedSidecar)
                    .help("When on, the app launches its own Python server on a free local port. Turn off to point at a remote backend (e.g. HF Spaces).")
                LabeledContent("Status", value: sidecar.state.statusLabel)
                    .font(.caption.monospaced())
                if case .running(let url) = sidecar.state {
                    LabeledContent("URL") {
                        Text(url.absoluteString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            #endif
            Section("Backend") {
                let urlField = TextField("http://localhost:8000",
                                         text: $settings.backendURL)
                    .autocorrectionDisabled()
                #if os(iOS)
                urlField
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                #else
                urlField
                #endif
                if settings.resolvedBaseURL == nil {
                    Label("URL is not valid", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            Section("Advanced") {
                NavigationLink {
                    ConvertView()
                } label: {
                    Label("Manual conversion", systemImage: "wand.and.stars")
                }
                NavigationLink {
                    JobsListView()
                } label: {
                    Label("Recent jobs", systemImage: "list.bullet.rectangle")
                }
                NavigationLink {
                    TelemetryView()
                } label: {
                    Label("Telemetry", systemImage: "speedometer")
                }
            }

            Section("About") {
                LabeledContent("Bundle ID", value: "com.pietrocode.epubtomp3")
                #if os(iOS)
                LabeledContent("Min iOS", value: "17.0")
                #elseif os(macOS)
                LabeledContent("Min macOS", value: "14.0")
                #endif
            }
        }
        .navigationTitle("Settings")
    }
}

#Preview("Settings") {
    NavigationStack {
        SettingsView()
    }
    .environment(AppSettings())
}
