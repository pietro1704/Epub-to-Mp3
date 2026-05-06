import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Backend") {
                TextField("http://localhost:8000",
                          text: $settings.backendURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if settings.resolvedBaseURL == nil {
                    Label("URL is not valid", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            Section("About") {
                LabeledContent("Bundle ID", value: "com.pietrocode.epubtomp3")
                LabeledContent("Min iOS", value: "17.0")
            }
        }
        .navigationTitle("Settings")
    }
}
