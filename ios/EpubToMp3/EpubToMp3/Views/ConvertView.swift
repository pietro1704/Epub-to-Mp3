import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ConvertViewModel: ObservableObject {
    @Published var selectedFile: URL? = nil
    @Published var engine: String = "edge"
    @Published var voice: String = ""
    @Published var language: String = ""
    @Published var chapters: String = ""
    @Published var clearCache: Bool = false
    @Published var forceReprocess: Bool = false
    @Published var maxPerformance: Bool = false

    @Published var isSubmitting: Bool = false
    @Published var submittedJobId: String? = nil
    @Published var error: String? = nil

    func submit(client: APIClient?) async {
        guard let client else {
            error = "No backend configured. Open Settings or wait for the embedded server."
            return
        }
        guard let file = selectedFile else {
            error = "Pick an EPUB or PDF first."
            return
        }
        isSubmitting = true
        error = nil
        submittedJobId = nil
        defer { isSubmitting = false }
        do {
            var opts = APIClient.ConvertOptions()
            opts.engine = engine
            if !voice.isEmpty { opts.voice = voice }
            if !language.isEmpty { opts.language = language }
            if !chapters.isEmpty { opts.chapters = chapters }
            opts.clearCache = clearCache
            opts.forceReprocess = forceReprocess
            opts.maxPerformance = maxPerformance
            #if os(macOS)
            // Desktop sidecar always lives on loopback, so the
            // local-path shortcut works.
            let response = try await client.submitConversion(localPath: file, options: opts)
            #else
            // iOS / iPadOS — read into memory and POST as multipart.
            let data = try Data(contentsOf: file)
            let response = try await client.submitConversion(
                uploadedFile: (data, file.lastPathComponent),
                options: opts
            )
            #endif
            submittedJobId = response.jobId
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}

struct ConvertView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var viewModel = ConvertViewModel()
    @State private var showingPicker = false

    private var client: APIClient? {
        settings.resolvedBaseURL.map(APIClient.init(baseURL:))
    }

    private static let acceptedTypes: [UTType] = {
        var types: [UTType] = [.epub, .pdf]
        if let zip = UTType("org.idpf.epub-container") { types.append(zip) }
        return types
    }()

    var body: some View {
        Form {
            Section("File") {
                if let file = viewModel.selectedFile {
                    LabeledContent("Selected") {
                        VStack(alignment: .leading) {
                            Text(file.lastPathComponent).font(.body)
                            Text(file.path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                } else {
                    Text("No file picked.").foregroundStyle(.secondary)
                }
                Button {
                    showingPicker = true
                } label: {
                    Label(viewModel.selectedFile == nil ? "Pick EPUB or PDF" : "Change file",
                          systemImage: "doc.badge.plus")
                }
            }

            Section("Engine") {
                Picker("Engine", selection: $viewModel.engine) {
                    Text("Edge-TTS (cloud)").tag("edge")
                    Text("Piper (offline)").tag("piper")
                    Text("Coqui XTTS").tag("coqui")
                }
                .pickerStyle(.segmented)
                TextField("Voice (optional)", text: $viewModel.voice)
                TextField("Language code (e.g. en, pt) — optional",
                          text: $viewModel.language)
            }

            Section("Chapters") {
                TextField("Chapter range (e.g. 3-7) — optional",
                          text: $viewModel.chapters)
                    .help("Leave empty to convert the whole book.")
            }

            Section("Flags") {
                Toggle("Clear cache before run", isOn: $viewModel.clearCache)
                Toggle("Force reprocess", isOn: $viewModel.forceReprocess)
                Toggle("Max performance", isOn: $viewModel.maxPerformance)
            }

            if let jobId = viewModel.submittedJobId {
                Section {
                    Label("Job submitted: \(jobId)", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    NavigationLink(value: jobId) {
                        Label("Open progress", systemImage: "arrow.right.circle")
                    }
                }
            }

            if let err = viewModel.error {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await viewModel.submit(client: client) }
                } label: {
                    HStack {
                        if viewModel.isSubmitting { ProgressView().controlSize(.small) }
                        Text(viewModel.isSubmitting ? "Submitting…" : "Start conversion")
                    }
                }
                .disabled(viewModel.isSubmitting || viewModel.selectedFile == nil)
            }
        }
        .navigationTitle("Convert")
        .navigationDestination(for: String.self) { jobId in
            JobDetailView(jobId: jobId)
        }
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: Self.acceptedTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                // Persist sandbox bookmark on macOS so the sidecar
                // (a separate process) can read the file via its path.
                #if os(macOS)
                _ = url.startAccessingSecurityScopedResource()
                #endif
                viewModel.selectedFile = url
            case .failure(let err):
                viewModel.error = err.localizedDescription
            }
        }
    }
}

#if DEBUG
#Preview("Convert") {
    NavigationStack { ConvertView() }
        .environmentObject(AppSettings())
}
#endif
