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
            // The job-queue / SSE pipeline relies on a reachable server.
            // On iOS the embedded runtime handles conversion via
            // `PythonBridge.convertEpub` directly (kicked off from
            // `BookOpenView.startAudioBootstrap`), so this form is only
            // surfaced for the explicit "send to remote" workflow.
            error = "The audio engine is still warming up. Try again in a moment, or set a remote backend URL in Settings."
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
                    CompatLabeledContent("Selected") {
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
                    if #available(iOS 16, macOS 13, *) {
                        NavigationLink(value: jobId) {
                            Label("Open progress", systemImage: "arrow.right.circle")
                        }
                    } else {
                        NavigationLink {
                            JobDetailView(jobId: jobId)
                        } label: {
                            Label("Open progress", systemImage: "arrow.right.circle")
                        }
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
        .compatConvertDestination()
        .background {
            Color.clear.allowsHitTesting(false)
                .fileImporter(
                    isPresented: $showingPicker,
                    allowedContentTypes: Self.acceptedTypes,
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls):
                        guard let url = urls.first else { return }
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
}

/// Value-based navigation destination requires iOS 16 / macOS 13.
/// The fallback path uses explicit `NavigationLink { destination }`
/// above (inside the "Open progress" section).
private extension View {
    @ViewBuilder
    func compatConvertDestination() -> some View {
        if #available(iOS 16, macOS 13, *) {
            self.navigationDestination(for: String.self) { jobId in
                JobDetailView(jobId: jobId)
            }
        } else {
            self
        }
    }
}

#if DEBUG
#Preview("Convert") {
    CompatNavigationStack { ConvertView() }
        .environmentObject(AppSettings())
}
#endif
