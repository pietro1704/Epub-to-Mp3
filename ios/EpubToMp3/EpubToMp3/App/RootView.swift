import SwiftUI

/// Top-level container. iOS/iPadOS now use a UIKit tab shell for the
/// main app chrome, while macOS keeps the existing SwiftUI split/tab
/// branch because UIKit is unavailable there. The reader/player layers
/// still sit above the shell so opening a book or the full player does
/// not tear down the underlying navigation hierarchy.
struct RootView: View {
    @EnvironmentObject private var audioWarmup: AudioEngineWarmup
    #if !os(iOS)
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playerPresentation: PlayerPresentation
    @EnvironmentObject private var readerCoordinator: ReaderCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(AudioPlayer.currentBookIDDefaultsKey)
    private var currentBookID: String?

    @AppStorage(MainReaderView.currentlyReadingBookIDKey)
    private var currentlyReadingBookID: String?
    @Environment(\.horizontalSizeClass) private var hSize

    private var useSplit: Bool { hSize == .regular }
    #endif

    #if !os(iOS)
    private var isReaderActive: Bool {
        guard let readingID = currentlyReadingBookID, !readingID.isEmpty else { return false }
        return library.books.contains(where: { $0.id == readingID })
    }

    private var showMiniPlayer: Bool {
        Self.shouldShowMiniPlayer(
            currentBookID: currentBookID,
            currentlyReadingBookID: currentlyReadingBookID,
            availableBookIDs: Set(library.books.map(\.id))
        )
    }

    static func shouldShowMiniPlayer(
        currentBookID: String?,
        currentlyReadingBookID: String?,
        availableBookIDs: Set<String>
    ) -> Bool {
        guard let currentBookID, !currentBookID.isEmpty else { return false }
        guard availableBookIDs.contains(currentBookID) else { return false }
        guard let currentlyReadingBookID, !currentlyReadingBookID.isEmpty else { return true }
        return currentBookID != currentlyReadingBookID
    }
    #endif

    var body: some View {
        #if os(iOS)
        // The native app delegate mounts IOSRootContainerController directly.
        // Keep this legacy preview surface inert so it cannot become a second
        // UIKit/SwiftUI shell by accident.
        EmptyView()
        #else
        ZStack {
            shellContent
                .zIndex(0)

            if isReaderActive {
                MainReaderView(onBrowseLibrary: {
                    currentlyReadingBookID = nil
                })
                .zIndex(1)
            }

            if showMiniPlayer {
                VStack {
                    Spacer()
                    // This branch is macOS-only — iOS/iPadOS never reaches
                    // This legacy compatibility surface is not mounted by
                    // the native application delegates.
                    MiniPlayerBar(onTap: { playerPresentation.showFullPlayer() })
                        .accessibilityIdentifier("miniPlayer.rootShell")
                }
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity)
                )
                .zIndex(2)
            }

            if playerPresentation.showingFullPlayer {
                FullPlayerSheet()
                    .environmentObject(player)
                    .environmentObject(library)
                    .environmentObject(playerPresentation)
                    .environmentObject(readerCoordinator)
                    .transition(.spotifyBottomSheet)
                    .zIndex(3)
                    .ignoresSafeArea()
            }
        }
        .overlay(alignment: .topTrailing) {
            AudioEngineWarmupBadge(warmup: audioWarmup)
                .padding(.top, 12)
                .padding(.trailing, 12)
                .zIndex(10)
        }
        .animation(
            reduceMotion
                ? .easeInOut(duration: 0.25)
                : .spring(response: 0.45, dampingFraction: 0.86),
            value: playerPresentation.showingFullPlayer
        )
        .alert(item: Binding(
            get: { player.lastError },
            set: { player.lastError = $0 }
        )) { error in
            Alert(
                title: Text(L10n.string("player.error.title")),
                message: Text(error.errorDescription ?? ""),
                dismissButton: .default(Text(L10n.string("common.ok")))
            )
        }
        #endif
    }

    #if !os(iOS)
    @ViewBuilder
    private var shellContent: some View {
        if useSplit {
            if #available(iOS 16, macOS 13, *) {
                SplitViewRoot()
            } else {
                TabRoot()
            }
        } else {
            TabRoot()
        }
    }
    #endif
}

/// Tabs surfaced by the iPhone-compact root. The raw values double as
/// `TabView` selection tokens so the empty-state CTAs inside individual
/// tabs can flip to the matching tab without reaching across the view tree.
///
/// Tab order (Apple Books HIG pattern — library owns book pushes):
///   0 library  — default landing: book catalog
///   1 settings — preferences
///   2 convert  — manual conversion workflow
enum RootTab: Int, Hashable {
    case library
    case settings
    case convert
}

/// The macOS tab fallback layout.
///
/// Tab order:
///   0 Library  — default landing: navigable book catalog
///   1 Settings — preferences
///   2 Convert  — manual conversion workflow
///
/// This no longer participates in the iOS/iPadOS app shell; UIKit owns
/// the mobile root. It remains as the SwiftUI fallback for the desktop
/// shell when split view is unavailable.
#if !os(iOS)
struct TabRoot: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playerPresentation: PlayerPresentation
    @EnvironmentObject private var readerCoordinator: ReaderCoordinator

    @State private var selectedTab: RootTab = .library
    @State private var readerChromeVisible = true

    @AppStorage(AudioPlayer.currentBookIDDefaultsKey)
    private var currentBookID: String?

    @AppStorage(MainReaderView.currentlyReadingBookIDKey)
    private var currentlyReadingBookID: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// True when the mini-player should be shown: a book is active in the library.
    private var showMiniPlayer: Bool {
        guard let id = currentBookID, !id.isEmpty else { return false }
        return library.books.contains(where: { $0.id == id }) && readerChromeVisible
    }

    var body: some View {
        ZStack {
            readerSurfaceOrTabs
                .zIndex(0)

            // FullPlayerSheet is presented in-tree (not as a system
            // .fullScreenCover) so the tab content remains alive below
            // while the player slides in from below the screen like
            // Spotify. Dismissal uses the same path in reverse.
            if playerPresentation.showingFullPlayer {
                FullPlayerSheet()
                    .environmentObject(player)
                    .environmentObject(library)
                    .environmentObject(playerPresentation)
                    .environmentObject(readerCoordinator)
                    .transition(.spotifyBottomSheet)
                    .zIndex(2)
                    .ignoresSafeArea()
            }
        }
        .animation(
            reduceMotion
                ? .easeInOut(duration: 0.25)
                : .spring(response: 0.45, dampingFraction: 0.86),
            value: playerPresentation.showingFullPlayer
        )
        // Single host for player-side error toasts. The AudioPlayer
        // publishes its `lastError` when a play / segment / write
        // operation fails silently. We use `.alert(item:)` (not
        // `.alert(isPresented:)`) so a new error fired DURING the
        // previous alert's dismiss animation re-presents instead of
        // being silently dropped — that race window is small but
        // very real for SSE segment streams that emit many errors in
        // a row when something goes wrong upstream.
        .alert(item: Binding(
            get: { player.lastError },
            set: { player.lastError = $0 }
        )) { error in
            Alert(
                title: Text(L10n.string("player.error.title")),
                message: Text(error.errorDescription ?? ""),
                dismissButton: .default(Text(L10n.string("common.ok")))
            )
        }
    }

    @ViewBuilder
    private var readerSurfaceOrTabs: some View {
        if let readingID = currentlyReadingBookID,
           library.books.contains(where: { $0.id == readingID }) {
            MainReaderView(onBrowseLibrary: {
                currentlyReadingBookID = nil
                selectedTab = .library
            })
        } else {
            tabContent
        }
    }

    private var tabContent: some View {
        TabView(selection: $selectedTab) {
            CompatNavigationStack {
                LibraryView()
            }
            .miniPlayerInset(visible: showMiniPlayer, onTap: { playerPresentation.showFullPlayer() })
            .tabItem { Label(L10n.string("nav.library"), systemImage: "books.vertical") }
            .tag(RootTab.library)

            CompatNavigationStack {
                SettingsView()
            }
            .miniPlayerInset(visible: showMiniPlayer, onTap: { playerPresentation.showFullPlayer() })
            .tabItem { Label(L10n.string("nav.settings"), systemImage: "gearshape") }
            .tag(RootTab.settings)

            CompatNavigationStack {
                ConvertView()
            }
            .miniPlayerInset(visible: showMiniPlayer, onTap: { playerPresentation.showFullPlayer() })
            .tabItem { Label(L10n.string("convert.title"), systemImage: "wand.and.stars") }
            .tag(RootTab.convert)
        }
        .onPreferenceChange(ReaderChromeVisiblePreferenceKey.self) { visible in
            readerChromeVisible = visible
        }
    }
}
#endif

/// Small app-wide badge shown while the embedded audio runtime starts.
/// The warm-up is process-lifetime state, not per-book state; keeping it
/// here prevents each reader open from racing Python bootstrap again.
struct AudioEngineWarmupBadge: View {
    @ObservedObject var warmup: AudioEngineWarmup
    @State private var showingDetails = false
    @State private var hiddenByUser = false

    var body: some View {
        Group {
            if warmup.isVisible && !hiddenByUser {
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: CGFloat(warmup.progress))
                            .stroke(warmupBadgeTint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text(warmup.progressLabel)
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(warmup.stateLabel)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(warmupBadgeTint)
                            Text(warmup.progressLabel)
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(warmup.message.isEmpty ? L10n.string("audioWarmup.starting") : warmup.message)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 280, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(warmupBadgeTint.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.18), radius: 12, y: 6)
                .onTapGesture { showingDetails = true }
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onEnded { value in
                            if value.translation.height < -24 {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    hiddenByUser = true
                                }
                            }
                        }
                )
                .sheet(isPresented: $showingDetails) {
                    AudioEngineWarmupDetailView(warmup: warmup)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(Text(warmup.message.isEmpty ? L10n.string("audioWarmup.accessibilityStarting") : warmup.message))
                .accessibilityHint(Text(L10n.string("audioWarmup.details.accessibilityHint")))
            }
        }
        .compatOnChange(of: warmup.state) { state in
            if state != .warming { hiddenByUser = false }
        }
    }

    private var warmupBadgeTint: Color {
        if case .failed = warmup.state { return .red }
        return .accentColor
    }
}

struct AudioEngineWarmupDetailView: View {
    @ObservedObject var warmup: AudioEngineWarmup
    @Environment(\.dismiss) private var dismiss

    private var percentText: String {
        "\(Int((warmup.progress * 100).rounded()))%"
    }

    private var stateText: String {
        switch warmup.state {
        case .idle: return L10n.string("audioWarmup.state.idle")
        case .warming: return L10n.string("audioWarmup.state.loading")
        case .ready: return L10n.string("audioWarmup.state.ready")
        case .failed: return L10n.string("audioWarmup.state.failed")
        }
    }

    var body: some View {
        CompatNavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 8)
                        Circle()
                            .trim(from: 0, to: CGFloat(warmup.progress))
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text(percentText)
                            .font(.headline.monospacedDigit())
                    }
                    .frame(width: 82, height: 82)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.string("audioWarmup.details.title"))
                            .font(.title3.weight(.semibold))
                        Text(stateText)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string("audioWarmup.details.status"))
                        .font(.headline)
                    Text(warmup.message.isEmpty ? L10n.string("audioWarmup.starting") : warmup.message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: warmup.progress)
                    .progressViewStyle(.linear)

                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle(L10n.string("audioWarmup.details.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.ok")) { dismiss() }
                }
            }
        }
    }
}

#Preview("Root") {
    RootView()
        .environmentObject(AppSettings())
        .environmentObject(LibraryStore())
        .environmentObject(AudioPlayer())
        .environmentObject(PlayerPresentation())
        .environmentObject(ReaderCoordinator())
        .environmentObject(BookmarkStore())
        .environmentObject(AudioEngineWarmup())
        #if os(macOS)
        .environmentObject(SidecarManager())
        #endif
}

struct ReaderChromeVisiblePreferenceKey: PreferenceKey {
    static var defaultValue: Bool = true

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value && nextValue()
    }
}

extension View {
    func readerChromeVisible(_ visible: Bool) -> some View {
        preference(key: ReaderChromeVisiblePreferenceKey.self, value: visible)
    }
}

// MARK: - Mini player inset modifier

private struct MiniPlayerInsetModifier: ViewModifier {
    let visible: Bool
    let onTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if visible {
                    MiniPlayerBar(onTap: onTap)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .move(edge: .bottom).combined(with: .opacity)
                        )
                        .accessibilityIdentifier("miniPlayer.tabBar")
                }
            }
            .animation(
                reduceMotion
                    ? .easeInOut(duration: 0.2)
                    : .spring(response: 0.3, dampingFraction: 0.8),
                value: visible
            )
    }
}

extension View {
    func miniPlayerInset(visible: Bool, onTap: @escaping () -> Void) -> some View {
        modifier(MiniPlayerInsetModifier(visible: visible, onTap: onTap))
    }
}

// MARK: - Full-player Spotify bottom-sheet transition

/// Native Spotify-style presentation: the full player lives in the same
/// view tree as the tab/split UI, but moves from just below the screen to
/// full screen. On dismiss it follows the exact reverse path back below
/// the bottom edge, while the underlying content remains mounted.
extension AnyTransition {
    static var spotifyBottomSheet: AnyTransition {
        .move(edge: .bottom)
    }
}

#if !os(iOS)
#Preview("Tab fallback") {
    TabRoot()
        .environmentObject(AppSettings())
        .environmentObject(LibraryStore())
        .environmentObject(AudioPlayer())
        .environmentObject(PlayerPresentation())
        .environmentObject(ReaderCoordinator())
        .environmentObject(BookmarkStore())
        #if os(macOS)
        .environmentObject(SidecarManager())
        #endif
}
#endif
