import SwiftUI
import AVFoundation
import MediaPlayer

struct ChapterListRowState: Equatable {
    let isCurrent: Bool
    let playableIndex: Int?

    var isPlayable: Bool { playableIndex != nil }

    static func resolve(
        chapter: JobSnapshot.Chapter,
        snapshot: JobSnapshot,
        currentPlayableIndex: Int
    ) -> ChapterListRowState {
        let playingEpubIndex = InstantReaderIndexMapper
            .epubIndex(forPlayableIndex: currentPlayableIndex, in: snapshot)
        let playableIndex = InstantReaderIndexMapper
            .playableIndex(forEpubIndex: chapter.index, in: snapshot)
        return ChapterListRowState(
            isCurrent: playingEpubIndex.map { $0 == chapter.index } ?? false,
            playableIndex: playableIndex
        )
    }
}

/// Full-screen audiobook player presented via `.fullScreenCover`.
/// Mirrors the Apple Music / Spotify full-player pattern:
///
///   ┌─────────────────────┐
///   │  [chevron.compact.down]  │  drag handle — swipe down to dismiss
///   │                     │
///   │   [cover art 300]   │
///   │   Book Title  XL    │
///   │   Author / chapter  │
///   │                     │
///   │  ─── scrubber ────  │
///   │  0:00          4:32 │
///   │                     │
///   │  |◀  ⏮  ▶  ⏭  ▶|  │  (skip-15 / play-pause / skip+15)
///   │                     │
///   │  speed  sleep  AirPlay │
///   └─────────────────────┘
///
/// Presentation: `.fullScreenCover(isPresented:)` — slides up from the
/// bottom, exactly like Spotify / Apple Music. Dismissed by swiping
/// down (custom drag gesture) or tapping the chevron handle.
struct FullPlayerSheet: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var library: LibraryStore

    @AppStorage(AudioPlayer.currentBookIDDefaultsKey)
    private var currentBookID: String?

    @AppStorage(AudioPlayer.currentChapterIndexDefaultsKey)
    private var currentChapterIndex: Int = 0

    @EnvironmentObject private var readerCoordinator: ReaderCoordinator
    private var readerChapterIndex: Int { readerCoordinator.anchor.chapterIndex }

    /// `.tertiary` foreground on `.thinMaterial` over album-art
    /// backdrop drops below WCAG AA in dark mode. When the user has
    /// opted into Increase Contrast we bump to `.secondary` so the
    /// chapter label stays readable.
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    private var increaseContrast: Bool { colorSchemeContrast == .increased }

    @Environment(\.dismiss) private var dismiss

    @State private var showChapterList = false
    @State private var dragOffset: CGFloat = 0
    @State private var pendingAnchor: PlayDivergenceAnchor?
    /// Local scrubber position while the user is dragging — decouples
    /// the visible thumb from `player.positionSeconds` so dragging
    /// doesn't fire a seek per CMTime tick. Committed back to the
    /// player on `onEditingChanged: { editing == false }`.
    @State private var scrubberDragValue: TimeInterval?

    // MARK: Derived state

    private var currentBook: BookEntity? {
        guard let id = currentBookID, !id.isEmpty else { return nil }
        return library.books.first { $0.id == id }
    }

    private var chapterLabel: String {
        let idx = player.snapshot != nil ? player.currentChapterIndex : currentChapterIndex
        guard let chapters = player.snapshot?.playableChapters,
              idx < chapters.count else {
            return L10n.string("player.chapter", idx + 1)
        }
        return chapters[idx].displayTitle
    }

    private var progress: Double {
        guard player.durationSeconds > 0 else { return 0 }
        return min(1, max(0, player.positionSeconds / player.durationSeconds))
    }

    // MARK: Body

    var body: some View {
        if #available(iOS 16, macOS 13, *) {
            modernBody
        } else {
            legacyBody
        }
    }

    @available(iOS 16, macOS 13, *)
    private var modernBody: some View {
        // All spacers normalised to the 8/16/24/32-pt rhythm Apple's
        // own player surfaces use. Previously these were 8/20/24/28/20/16
        // — three values off-grid which made the vertical rhythm feel
        // arbitrary on a careful look.
        VStack(spacing: 0) {
            dragHandle
            Spacer(minLength: 8)
            coverHero
            Spacer(minLength: 16)
            titleBlock
            Spacer(minLength: 24)
            scrubberBlock
            Spacer(minLength: 24)
            transportRow
            Spacer(minLength: 16)
            secondaryRow
            Spacer(minLength: 16)
        }
        // 24pt of inner horizontal padding on top of the safe-area
        // insets — keeps the lateral transport buttons clear of the
        // screen edge on every iPhone (notched, non-notched, SE).
        .compatHorizontalSafeAreaPadding(24)
        .background(backgroundLayer.ignoresSafeArea())
        .offset(y: max(0, dragOffset))
        .gesture(dismissDragGesture)
        .accessibilityAction(.escape) { dismiss() }
    }

    /// iOS 15 fallback: plain scroll layout without NavigationStack.
    /// The drag gesture is on the handle only (not the whole view) to
    /// avoid conflicting with ScrollView's built-in scroll gesture.
    private var legacyBody: some View {
        VStack(spacing: 0) {
            dragHandle
                .gesture(dismissDragGesture)
            ScrollView {
                // VStack spacing on 8pt grid (24 between section
                // groups). 28 was the previous value — off-grid.
                VStack(spacing: 24) {
                    Spacer(minLength: 16)
                    coverHero
                    titleBlock
                    scrubberBlock
                    transportRow
                    secondaryRow
                    Spacer(minLength: 24)
                    Button(L10n.string("player.close")) { dismiss() }
                        .buttonStyle(.bordered)
                    Spacer(minLength: 24)
                }
                .compatHorizontalSafeAreaPadding(24)
            }
            .scrollBounceBehaviorIfAvailable()
        }
        .background(backgroundLayer.ignoresSafeArea())
        .offset(y: max(0, dragOffset))
        .accessibilityAction(.escape) { dismiss() }
    }

    // MARK: - Drag handle + swipe-to-dismiss

    /// Visual drag indicator at the top. Tapping dismisses; dragging
    /// down past 120pt triggers dismiss with a spring animation.
    private var dragHandle: some View {
        Button { dismiss() } label: {
            VStack(spacing: 6) {
                Capsule()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 36, height: 5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string("player.close"))
        .accessibilityHint(L10n.string("miniPlayer.expandHint"))
    }

    /// Drag gesture: pulling down offsets the view; releasing past the
    /// threshold dismisses. The 120pt threshold prevents accidental
    /// dismisses while interacting with the scrubber.
    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .global)
            .onChanged { value in
                // Only track downward drags.
                if value.translation.height > 0 {
                    dragOffset = value.translation.height
                }
            }
            .onEnded { value in
                if value.translation.height > 120 || value.predictedEndTranslation.height > 300 {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        dragOffset = 0
                    }
                }
            }
    }

    // MARK: - Cover hero

    private var coverHero: some View {
        // Cover scales to ~70% of the screen width on every device:
        // 220pt cap was dwarfed on iPhone 15 Pro Max (430pt → cover
        // was 51% wide and the title block sat at 100% — visual
        // hierarchy inverted). Apple Music caps at the same ratio.
        // `containerRelativeFrame` (iOS 17+) reads the parent's
        // width; pre-iOS-17 falls back to a GeometryReader on
        // `.frame(maxWidth:)`. The 320pt hard cap protects iPad
        // landscape and macOS where the parent expands wide.
        Group {
            if let book = currentBook,
               let data = book.coverPNG,
               let img = platformImage(from: data) {
                img
                    .resizable()
                    .aspectRatio(2.0/3.0, contentMode: .fit)
                    .modifier(CoverHeroSizing())
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
                    .accessibilityLabel(L10n.string("player.coverArt", book.resolvedTitle))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.accentColor.opacity(0.15))
                    Image(systemName: "headphones")
                        .font(.system(size: 60, weight: .ultraLight))
                        .foregroundStyle(.tint)
                }
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .modifier(CoverHeroSizing())
                .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
                .accessibilityHidden(true)
            }
        }
        // Subtle scale-up on appear — matches Apple Music entry animation.
        .scaleEffect(1.0)
        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: currentBookID)
    }

    // MARK: - Title block

    private var titleBlock: some View {
        VStack(spacing: 6) {
            if let book = currentBook {
                Text(book.resolvedTitle)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let author = book.author, !author.isEmpty {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(chapterLabel)
                .font(.footnote)
                .foregroundStyle(increaseContrast ? .secondary : .tertiary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Scrubber

    private var scrubberBlock: some View {
        VStack(spacing: 6) {
            // The scrubber decouples its visible thumb from the
            // player while the user is dragging — `scrubberDragValue`
            // owns the local preview, and the seek only fires when
            // the gesture ends. Without this, every CMTime tick (~60
            // Hz on a drag) called `AVQueuePlayer.seek(to:)`, which
            // posts decode work to the asset queue; on older devices
            // the playhead stuttered or "jumped" back as the system
            // caught up.
            Slider(
                value: Binding(
                    get: { scrubberDragValue ?? player.positionSeconds },
                    set: { scrubberDragValue = $0 }
                ),
                in: 0...max(player.durationSeconds, 1),
                onEditingChanged: { editing in
                    #if os(iOS)
                    let generator = UIImpactFeedbackGenerator(style: editing ? .light : .medium)
                    generator.impactOccurred()
                    #endif
                    if !editing, let target = scrubberDragValue {
                        player.seek(to: target)
                        scrubberDragValue = nil
                    }
                }
            )
            // Scrubber follows HIG (Apple Books / Music): accent
            // tint on the filled portion so the interactive state
            // reads as "tap-and-drag-able". Forcing `.primary`
            // (black/white) reads as inert chrome on first glance.
            .accessibilityLabel(L10n.string("player.playbackPosition"))
            .accessibilityValue(formatTime(scrubberDragValue ?? player.positionSeconds))

            HStack {
                Text(formatTime(player.positionSeconds))
                Spacer()
                let remaining = player.durationSeconds - player.positionSeconds
                let remainingAtCurrentSpeed = remaining / Double(player.rate.rawValue)
                Text("-" + formatTime(remainingAtCurrentSpeed))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Transport row

    /// Full transport row, Apple Books / Music style: prev-chapter,
    /// skip-back-15, play/pause (large), skip-forward-15, next-chapter.
    /// The "..." menu sits below in `secondaryRow` for speed / sleep /
    /// chapter list / AirPlay.
    private var transportRow: some View {
        HStack(spacing: 0) {
            Spacer()
            Button { player.previousChapter() } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 22))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("player.previousChapter"))
            Spacer()
            Button { player.skipBackward(seconds: 15) } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 28))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("player.skipBack15"))
            Spacer()
            Button { handlePlayTap() } label: {
                ZStack {
                    if player.isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.primary)
                            .frame(width: 64, height: 64)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                            .frame(width: 64, height: 64)
                    }
                }
            }
            .buttonStyle(.plain)
            .tint(.primary)
            .accessibilityLabel(player.isPlaying ? L10n.string("player.pause") : L10n.string("player.play"))
            .playDivergenceDialog(player: player, anchor: $pendingAnchor)
            Spacer()
            Button { player.skipForward(seconds: 15) } label: {
                Image(systemName: "goforward.15")
                    .font(.system(size: 28))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("player.skipForward15"))
            Spacer()
            Button { player.nextChapter() } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 22))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("player.nextChapter"))
            Spacer()
        }
    }

    /// Secondary row below the transport: speed pill, chapter list,
    /// sleep timer, AirPlay. Brings back the full Apple Music-style
    /// surface the user asked for ("no player expandido devem
    /// aparecer todos os controles").
    private var secondaryRow: some View {
        HStack(spacing: 16) {
            // Speed
            Menu {
                ForEach(PlaybackRate.allCases) { rate in
                    Button {
                        player.setRate(rate)
                    } label: {
                        if player.rate == rate {
                            Label(rate.shortLabel, systemImage: "checkmark")
                        } else {
                            Text(rate.shortLabel)
                        }
                    }
                }
            } label: {
                Text(player.rate.shortLabel)
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 56, minHeight: 36)
                    .padding(.horizontal, 10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel(L10n.string("player.playbackSpeed", player.rate.shortLabel))

            Spacer()

            Button { showChapterList = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("player.chapters"))
            .sheet(isPresented: $showChapterList) {
                ChapterListSheet(player: player)
            }

            Spacer()

            // Sleep timer
            Menu {
                ForEach([0, 5, 15, 30, 45, 60], id: \.self) { minutes in
                    Button {
                        if minutes == 0 {
                            player.setSleepTimer(seconds: 0)
                        } else {
                            player.startSleepTimer(minutes: minutes)
                        }
                    } label: {
                        if minutes == 0 {
                            Label(L10n.string("player.sleepTimerOption.off"), systemImage: "xmark")
                        } else {
                            Text(L10n.string("player.sleepTimerOption.\(minutes)"))
                        }
                    }
                }
            } label: {
                Image(systemName: player.sleepTimerRemaining > 0 ? "moon.zzz.fill" : "moon.zzz")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.string("player.sleepTimer"))

            Spacer()

            #if os(iOS)
            AirPlayPickerView()
                .frame(width: 44, height: 44)
                .accessibilityLabel(L10n.string("player.airplay"))
            #endif
        }
    }

    /// "..." popover menu — single overflow target for speed, sleep,
    /// chapter list, previous chapter / skip-back, AirPlay. HIG keeps
    /// the primary control surface uncluttered; secondary controls go
    /// in `Menu`.
    private var playerMoreMenu: some View {
        Menu {
            // Playback speed submenu
            Menu {
                ForEach(PlaybackRate.allCases) { rate in
                    Button {
                        player.setRate(rate)
                    } label: {
                        if player.rate == rate {
                            Label(rate.shortLabel, systemImage: "checkmark")
                        } else {
                            Text(rate.shortLabel)
                        }
                    }
                }
            } label: {
                Label(
                    L10n.string("player.playbackSpeed", player.rate.shortLabel),
                    systemImage: "speedometer"
                )
            }

            // Sleep timer submenu
            Menu {
                ForEach([0, 5, 15, 30, 45, 60], id: \.self) { minutes in
                    Button {
                        if minutes == 0 {
                            player.setSleepTimer(seconds: 0)
                        } else {
                            player.startSleepTimer(minutes: minutes)
                        }
                    } label: {
                        if minutes == 0 {
                            Label(L10n.string("player.sleepTimerOption.off"), systemImage: "xmark")
                        } else {
                            Text(L10n.string("player.sleepTimerOption.\(minutes)"))
                        }
                    }
                }
            } label: {
                Label(L10n.string("player.sleepTimer"), systemImage: "moon.zzz")
            }

            Divider()

            Button { player.previousChapter() } label: {
                Label(L10n.string("player.previousChapter"), systemImage: "backward.end.fill")
            }
            Button { player.skipBackward(seconds: 15) } label: {
                Label(L10n.string("player.skipBack15"), systemImage: "gobackward.15")
            }
            Button { player.skipForward(seconds: 15) } label: {
                Label(L10n.string("player.skipForward15"), systemImage: "goforward.15")
            }

            Divider()

            Button { showChapterList = true } label: {
                Label(L10n.string("player.chapters"), systemImage: "list.bullet")
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 32))
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(L10n.string("player.more"))
        .sheet(isPresented: $showChapterList) {
            ChapterListSheet(player: player)
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var backgroundLayer: some View {
        // Use `.thinMaterial` as the backdrop so artwork colours
        // show through on iOS; macOS uses its own window chrome.
        Color.clear
            .background(.thinMaterial)
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: Play / divergence routing — see AudioPlayer for shared
    // decision logic and `.playDivergenceDialog` for the dialog UI.

    private func handlePlayTap() {
        switch player.playTapDecision(readerChapterIndex: readerChapterIndex) {
        case .pause, .resume:
            player.togglePlayPause()
        case .offerStartChoice:
            pendingAnchor = .capture(from: readerCoordinator)
        }
    }
}

// MARK: - Sleep timer button

/// Inline sleep-timer affordance: tap to cycle through presets, shows
/// remaining time when active (Apple Podcasts pattern).
private struct SleepTimerButton: View {
    @EnvironmentObject private var player: AudioPlayer

    private let presets: [TimeInterval] = [0, 15*60, 30*60, 45*60, 60*60]

    var body: some View {
        Button {
            cycleTimer()
        } label: {
            Label {
                if player.sleepTimerRemaining > 0 {
                    Text(formatRemaining(player.sleepTimerRemaining))
                        .monospacedDigit()
                } else {
                    Text(L10n.string("player.sleep"))
                }
            } icon: {
                Image(systemName: "moon.zzz")
            }
            .font(.subheadline.weight(.semibold))
            .frame(minWidth: 70, minHeight: 44)
            .padding(.horizontal, 10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            player.sleepTimerRemaining > 0
                ? L10n.string("player.sleepTimerRemaining", formatRemaining(player.sleepTimerRemaining))
                : L10n.string("player.sleepTimerOff")
        )
    }

    private func cycleTimer() {
        let current = player.sleepTimerRemaining
        let next = presets.first { $0 > current } ?? 0
        player.setSleepTimer(seconds: next)
    }

    private func formatRemaining(_ secs: TimeInterval) -> String {
        let m = Int(secs) / 60
        let s = Int(secs) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - View modifier helpers (availability-gated API)

private extension View {
    /// Bounce behaviour polyfill — only exists on iOS 16.4+.
    @ViewBuilder
    func scrollBounceBehaviorIfAvailable() -> some View {
        if #available(iOS 16.4, macOS 13.3, *) {
            self.scrollBounceBehavior(.basedOnSize)
        } else {
            self
        }
    }
}

// MARK: - Chapter list sheet

/// Sheet presenting chapters from the current snapshot for in-player navigation.
private struct ChapterListSheet: View {
    @ObservedObject var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss

    private var chapters: [JobSnapshot.Chapter] {
        player.snapshot?.chapterProgress ?? []
    }

    var body: some View {
        CompatNavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(chapters) { chapter in
                        chapterRow(chapter)
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .navigationTitle(L10n.string("player.chapters"))
            .compatInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("readerSettings.done")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func chapterRow(_ chapter: JobSnapshot.Chapter) -> some View {
        // SOURCE OF TRUTH: `player.currentChapterIndex` is an index into
        // `playableChapters` (the filtered, playable subset), NOT into
        // the full `chapterProgress` list we iterate here. Comparing
        // `chapter.index` (the original EPUB index, sparse) against it
        // highlighted the wrong row whenever any chapter was skipped /
        // unplayable. Resolve through the playable subset.
        let state = player.snapshot.map {
            ChapterListRowState.resolve(
                chapter: chapter,
                snapshot: $0,
                currentPlayableIndex: player.currentChapterIndex
            )
        }
        let isCurrent = state?.isCurrent ?? false
        // Chapters in `chapterProgress` that have no audio file (no
        // `downloadUrl`, or never made it into `playableChapters`)
        // would silently no-op if the user tapped them. Mark those
        // rows visually disabled so the user knows audio jumps are
        // unavailable there — they remain visible because the TOC
        // structure is informational regardless of audio readiness.
        let playableIndex = state?.playableIndex
        let isPlayable = state?.isPlayable ?? false
        Button {
            if let snapshot = player.snapshot, let playableIndex {
                player.play(snapshot: snapshot, startingAt: playableIndex)
            }
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chapter.displayTitle)
                        .font(.body)
                        .foregroundStyle(
                            isCurrent ? Color.accentColor
                            : (isPlayable ? .primary : .secondary)
                        )
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                        .accessibilityHidden(true)
                } else if !isPlayable {
                    Image(systemName: "speaker.slash")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isPlayable)
        .accessibilityLabel(
            isCurrent
                ? L10n.string("chapterList.nowPlaying", chapter.displayTitle)
                : (isPlayable
                    ? chapter.displayTitle
                    : L10n.string("chapterList.noAudio", chapter.displayTitle))
        )
        .accessibilityHint(isPlayable ? L10n.string("chapterList.doubleTapToPlay") : "")
        // VoiceOver should not call disabled rows a "button". The
        // `.disabled` modifier dims visually but keeps the .isButton
        // trait, which misleads VoiceOver users into trying to tap.
        .modifier(RemoveButtonTraitIfDisabledModifier(disabled: !isPlayable))
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Cover hero sizing

/// Cap the cover hero at 70% of the parent container width with a
/// 320pt floor (iPad landscape / macOS where the parent is wide).
/// On iOS 17+ we use `containerRelativeFrame` for a native ratio
/// binding; the fallback uses GeometryReader.
private struct CoverHeroSizing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17, macOS 14, *) {
            content.containerRelativeFrame(.horizontal) { width, _ in
                min(320, max(180, width * 0.7))
            }
        } else {
            GeometryReader { proxy in
                let target = min(320, max(180, proxy.size.width * 0.7))
                content
                    .frame(maxWidth: target)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
        }
    }
}

// MARK: - Accessibility helpers

/// VoiceOver workaround: `.disabled(true)` leaves the `.isButton`
/// trait in place, so VoiceOver still announces the row as a button
/// even though tapping does nothing. Strip the trait when disabled
/// so a11y users perceive these rows as informational only.
private struct RemoveButtonTraitIfDisabledModifier: ViewModifier {
    let disabled: Bool
    func body(content: Content) -> some View {
        if disabled {
            content.accessibilityRemoveTraits(.isButton)
        } else {
            content
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Full Player Sheet") {
    let lib = LibraryStore.previewPopulated
    let player = AudioPlayer()
    if let first = lib.books.first {
        UserDefaults.standard.set(first.id, forKey: AudioPlayer.currentBookIDDefaultsKey)
    }
    return FullPlayerSheet()
        .environmentObject(player)
        .environmentObject(lib)
}
#endif
