import SwiftUI
import UniformTypeIdentifiers

#if !os(iOS)
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
            error = L10n.string("convert.error.engineWarmingUp")
            return
        }
        guard let file = selectedFile else {
            error = L10n.string("convert.error.pickFileFirst")
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
            // Desktop sidecar always lives on loopback, so the
            // local-path shortcut works.
            let response = try await client.submitConversion(localPath: file, options: opts)
            submittedJobId = response.jobId
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    #if os(macOS)
    /// Copies a user-selected document into an app-owned Application Support
    /// inbox under a *balanced* security scope, returning the durable copy.
    ///
    /// Mirrors `LibraryStore`'s import policy: the external file is only
    /// touched under a short-lived `startAccessingSecurityScopedResource()` /
    /// `stopAccessingSecurityScopedResource()` pair, and the conversion then
    /// reads the internal copy. This avoids leaving a security scope open for
    /// the lifetime of the selection (the previous behavior) and prevents
    /// repeat macOS document-access prompts on later launches. The original
    /// selected file is preserved.
    static func importForConversion(
        _ url: URL,
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil
    ) throws -> URL {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let inbox = try conversionInboxDirectory(
            fileManager: fileManager,
            baseDirectory: baseDirectory
        )
        // Retain only the active selection so the inbox stays bounded.
        if fileManager.fileExists(atPath: inbox.path) {
            try? fileManager.removeItem(at: inbox)
        }
        try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)

        let name = url.lastPathComponent.isEmpty ? "Book" : url.lastPathComponent
        let destination = inbox.appendingPathComponent(name, isDirectory: false)
        try fileManager.copyItem(at: url, to: destination)
        return destination
    }

    static func conversionInboxDirectory(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil
    ) throws -> URL {
        if let baseDirectory { return baseDirectory }
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appendingPathComponent("EpubToMp3", isDirectory: true)
            .appendingPathComponent("ConversionInbox", isDirectory: true)
    }
    #endif
}
#endif

#if os(iOS)
struct ConvertView: View {
    var body: some View {
        EmptyView()
    }
}
#else
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
            Section(L10n.string("convert.file")) {
                if let file = viewModel.selectedFile {
                    CompatLabeledContent(L10n.string("convert.selected")) {
                        VStack(alignment: .leading) {
                            Text(file.lastPathComponent).font(.body)
                            Text(file.path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                } else {
                    Text(localized: "convert.noFilePicked").foregroundStyle(.secondary)
                }
                Button {
                    showingPicker = true
                } label: {
                    Label(viewModel.selectedFile == nil
                            ? L10n.string("convert.pickFile")
                            : L10n.string("convert.changeFile"),
                          systemImage: "doc.badge.plus")
                }
            }

            Section(L10n.string("convert.engine")) {
                Picker(L10n.string("convert.engine"), selection: $viewModel.engine) {
                    Text(verbatim: "Edge-TTS (\(L10n.string("convert.engine.cloud")))").tag("edge")
                    Text(verbatim: "Piper (\(L10n.string("convert.engine.offline")))").tag("piper")
                    Text(verbatim: "Coqui XTTS").tag("coqui")
                }
                .pickerStyle(.segmented)
                TextField(L10n.string("convert.voiceOptional"), text: $viewModel.voice)
                TextField(L10n.string("convert.languageOptional"),
                          text: $viewModel.language)
            }

            Section(L10n.string("convert.chapters")) {
                TextField(L10n.string("convert.chapterRangeOptional"),
                          text: $viewModel.chapters)
                    .help(L10n.string("convert.chapterRangeHelp"))
            }

            Section(L10n.string("convert.flags")) {
                Toggle(L10n.string("convert.clearCache"), isOn: $viewModel.clearCache)
                Toggle(L10n.string("convert.forceReprocess"), isOn: $viewModel.forceReprocess)
                Toggle(L10n.string("convert.maxPerformance"), isOn: $viewModel.maxPerformance)
            }

            if let jobId = viewModel.submittedJobId {
                Section {
                    Label(L10n.string("convert.jobSubmitted", jobId), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    if #available(macOS 13, *) {
                        NavigationLink(value: jobId) {
                            Label(L10n.string("convert.openProgress"), systemImage: "arrow.right.circle")
                        }
                    } else {
                        NavigationLink {
                            JobDetailView(jobId: jobId)
                        } label: {
                            Label(L10n.string("convert.openProgress"), systemImage: "arrow.right.circle")
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
                        Text(viewModel.isSubmitting
                                ? L10n.string("convert.submitting")
                                : L10n.string("convert.startConversion"))
                    }
                }
                .disabled(viewModel.isSubmitting || viewModel.selectedFile == nil)
            }
        }
        .padding(.bottom, MiniPlayerBar.reservedHeight)
        .navigationTitle(L10n.string("convert.title"))
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
                        // Copy into app-owned storage under a balanced scope
                        // instead of holding the external scope open forever.
                        do {
                            viewModel.selectedFile =
                                try ConvertViewModel.importForConversion(url)
                        } catch {
                            viewModel.error = error.localizedDescription
                        }
                        #else
                        viewModel.selectedFile = url
                        #endif
                    case .failure(let err):
                        viewModel.error = err.localizedDescription
                    }
                }
        }
    }
}
#endif

/// Value-based navigation destination requires iOS 16 / macOS 13.
/// The fallback path uses explicit `NavigationLink { destination }`
/// above (inside the "Open progress" section).
private extension View {
    @ViewBuilder
    func compatConvertDestination() -> some View {
        if #available(macOS 13, *) {
            self.navigationDestination(for: String.self) { jobId in
                JobDetailView(jobId: jobId)
            }
        } else {
            self
        }
    }
}

#if DEBUG && !os(iOS)
#Preview("Convert") {
    CompatNavigationStack { ConvertView() }
        .environmentObject(AppSettings())
        .environmentObject(LibraryStore())
        .environmentObject(AudioPlayer())
        .environmentObject(PlaybackClock())
}
#endif
