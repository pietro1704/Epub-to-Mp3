import SwiftUI
#if !os(iOS)
import AVFoundation
import MediaPlayer
#endif

struct FullPlayerLyricsState {
    static let tutorialSeenKey = "fullPlayer.coverLyricsTutorialSeen"

    static func currentSentenceText(
        spans: [SentenceSpan],
        syncSentenceId: String?,
        activeSentenceId: String?
    ) -> String? {
        let preferredId = activeSentenceId ?? syncSentenceId
        guard let preferredId else { return nil }
        return spans.first(where: { $0.id == preferredId })?.text
    }
}

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
#if os(iOS)
struct FullPlayerSheet: View {
    var body: some View {
        EmptyView()
    }
}
#else
struct FullPlayerSheet: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var playbackClock: PlaybackClock
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playerPresentation: PlayerPresentation

    @AppStorage(AudioPlayer.currentBookIDDefaultsKey)
    private var currentBookID: String?

    @AppStorage(AudioPlayer.currentChapterIndexDefaultsKey)
    private var currentChapterIndex: Int = 0

    @EnvironmentObject private var readerCoordinator: ReaderCoordinator
    private var readerChapterIndex: Int { readerCoordinator.anchor.chapterIndex }
    private var readerPageRatio: Double? { readerCoordinator.anchor.pageRatio }

    /// `.tertiary` foreground on `.thinMaterial` over album-art
    /// backdrop drops below WCAG AA in dark mode. When the user has
    /// opted into Increase Contrast we bump to `.secondary` so the
    /// chapter label stays readable.
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    private var increaseContrast: Bool { colorSchemeContrast == .increased }

    @Environment(\.dismiss) private var dismiss

    @State private var showChapterList = false
    @State private var showingRatePicker = false
    @State private var dragOffset: CGFloat = 0

    @State private var showLyricsOverlay = false
    @State private var fulltext: EbookFulltext?
    @State private var lyricSync = SyncEngine()
    @State private var lyricSpans: [SentenceSpan] = []
    @State private var lyricSentenceId: String?
    @AppStorage(FullPlayerLyricsState.tutorialSeenKey)
    private var coverLyricsTutorialSeen: Bool = false
    /// Local scrubber position while the user is dragging — decouples
    /// the visible thumb from `playbackClock.positionSeconds` so dragging
    /// doesn't fire a seek per CMTime tick. Committed back to the
    /// player on `onEditingChanged: { editing == false }`.
    @State private var scrubberDragValue: TimeInterval?

    // MARK: Derived state

    private var currentBook: BookEntity? {
        guard let id = currentBookID, !id.isEmpty else { return nil }
        return library.books.first { $0.id == id }
    }

    private var chapterLabel: String {
        guard player.snapshot != nil else {
            return L10n.string("player.chapter", currentChapterIndex + 1)
        }
        return player.effectiveChapterTitle
    }

    private var progress: Double {
        guard playbackClock.durationSeconds > 0 else { return 0 }
        return min(1, max(0, playbackClock.positionSeconds / playbackClock.durationSeconds))
    }

    private var currentLyricText: String? {
        FullPlayerLyricsState.currentSentenceText(
            spans: lyricSpans,
            syncSentenceId: lyricSentenceId,
            activeSentenceId: player.activeSentenceId
        )
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
            SystemVolumeSlider()
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
        .accessibilityAction(.escape) { dismissPlayer() }
        .task(id: currentBookID) { await loadLyricsFulltext() }
        .compatOnChange(of: player.currentChapterIndex) { _ in prepareLyricsChapter() }
        .compatOnChange(of: playbackClock.durationSeconds) { _ in prepareLyricsChapter() }
        // `player.position` ticks at ~4 Hz. Writing `@State lyricSentenceId`
        // on every tick re-evaluates this whole body (1086 lines) even
        // while `lyricsOverlay` is closed and `currentLyricText` isn't
        // being read anywhere — the exact per-tick cost the CADisplayLink
        // progress-bar migration removed elsewhere. `.task(id:
        // showLyricsOverlay)` cancels/restarts this loop when the overlay
        // toggles, so the position stream — and the state writes — only
        // run while lyrics are actually visible.
        .task(id: showLyricsOverlay) {
            guard showLyricsOverlay else { return }
            for await position in player.position {
                guard !Task.isCancelled else { break }
                lyricSentenceId = lyricSync.update(positionSeconds: position)
            }
        }
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
                    SystemVolumeSlider()
                    secondaryRow
                    Spacer(minLength: 24)
                    Button(L10n.string("player.close")) { dismissPlayer() }
                        .buttonStyle(.bordered)
                    Spacer(minLength: 24)
                }
                .compatHorizontalSafeAreaPadding(24)
            }
            .scrollBounceBehaviorIfAvailable()
        }
        .background(backgroundLayer.ignoresSafeArea())
        .offset(y: max(0, dragOffset))
        .accessibilityAction(.escape) { dismissPlayer() }
        .task(id: currentBookID) { await loadLyricsFulltext() }
        .compatOnChange(of: player.currentChapterIndex) { _ in prepareLyricsChapter() }
        .compatOnChange(of: playbackClock.durationSeconds) { _ in prepareLyricsChapter() }
        // `player.position` ticks at ~4 Hz. Writing `@State lyricSentenceId`
        // on every tick re-evaluates this whole body (1086 lines) even
        // while `lyricsOverlay` is closed and `currentLyricText` isn't
        // being read anywhere — the exact per-tick cost the CADisplayLink
        // progress-bar migration removed elsewhere. `.task(id:
        // showLyricsOverlay)` cancels/restarts this loop when the overlay
        // toggles, so the position stream — and the state writes — only
        // run while lyrics are actually visible.
        .task(id: showLyricsOverlay) {
            guard showLyricsOverlay else { return }
            for await position in player.position {
                guard !Task.isCancelled else { break }
                lyricSentenceId = lyricSync.update(positionSeconds: position)
            }
        }
    }

    // MARK: - Drag handle + swipe-to-dismiss

    /// Visual drag indicator at the top. Tapping dismisses; dragging
    /// down past 120pt triggers dismiss with a spring animation.
    private var dragHandle: some View {
        HStack {
            Spacer()
            Button { dismissPlayer() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("fullPlayer.close")
            .accessibilityLabel(L10n.string("player.close"))
        }
        .overlay {
            Button { dismissPlayer() } label: {
                Capsule()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 36, height: 5)
                    .frame(width: 72, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
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
                    dismissPlayer()
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
            coverArtwork
                .overlay {
                    if showLyricsOverlay {
                        lyricsOverlay
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    } else if !coverLyricsTutorialSeen {
                        coverTapTutorial
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                coverLyricsTutorialSeen = true
                showLyricsOverlay.toggle()
            }
        }
        // Subtle scale-up on appear — matches Apple Music entry animation.
        .scaleEffect(1.0)
        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: currentBookID)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(L10n.string("player.lyricsTapHint"))
    }

    @ViewBuilder
    private var coverArtwork: some View {
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
    }

    private var lyricsOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0.25)],
                startPoint: .bottom,
                endPoint: .top
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(spacing: 14) {
                Text(L10n.string("player.nowReading"))
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.72))

                Text(currentLyricText ?? L10n.string("player.lyricsWaiting"))
                    .font(.title3.weight(.semibold))
                    .lineSpacing(6)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.72)
            }
            .padding(24)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(currentLyricText ?? L10n.string("player.lyricsWaiting"))
    }

    private var coverTapTutorial: some View {
        VStack {
            Spacer()
            Label(L10n.string("player.coverTapTutorial"), systemImage: "hand.tap")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.62), in: Capsule())
                .padding(.bottom, 14)
        }
        .allowsHitTesting(false)
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
            #if canImport(UIKit)
            if let snapshot = player.snapshot, snapshot.chapterProgress?.isEmpty == false {
                SegmentedPlaybackProgressBar(
                    bookProgressProvider: { [player] in player.cachedBookChapterProgress },
                    currentPlayableIndexProvider: { [player] in player.currentChapterIndex }
                )
                .frame(height: 6)
                .accessibilityIdentifier("fullPlayer.bookProgress")
            }
            #else
            if let snapshot = player.snapshot, snapshot.chapterProgress?.isEmpty == false {
                segmentedBookProgress(BookChapterProgress(snapshot: snapshot))
            }
            #endif
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
                    get: { scrubberDragValue ?? playbackClock.positionSeconds },
                    set: { scrubberDragValue = $0 }
                ),
                in: 0...max(playbackClock.durationSeconds, 1),
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
            .accessibilityValue(formatTime(scrubberDragValue ?? playbackClock.positionSeconds))

            HStack {
                Text(formatTime(playbackClock.positionSeconds))
                Spacer()
                let remaining = playbackClock.durationSeconds - playbackClock.positionSeconds
                let remainingAtCurrentSpeed = remaining / Double(player.rate.rawValue)
                Text("-" + formatTime(remainingAtCurrentSpeed))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }

    private func segmentedBookProgress(_ model: BookChapterProgress) -> some View {
        GeometryReader { geometry in
            let totalWeight = max(1, model.chapters.reduce(0) { $0 + $1.weight })
            HStack(spacing: 1) {
                ForEach(model.chapters) { chapter in
                    Capsule()
                        .fill(segmentColor(for: chapter))
                        .overlay {
                            if chapter.playableIndex == player.currentChapterIndex {
                                Capsule().stroke(.primary, lineWidth: 1)
                            }
                        }
                        .frame(width: max(2, geometry.size.width * chapter.weight / totalWeight))
                        .accessibilityLabel(chapter.title)
                        .accessibilityValue("\(Int(chapter.ratio * 100)) percent")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Book progress")
            .accessibilityValue("\(Int(model.overallRatio * 100)) percent")
        }
        .frame(height: 6)
        .accessibilityIdentifier("fullPlayer.bookProgress")
    }

    private func segmentColor(for chapter: BookChapterProgress.Chapter) -> Color {
        switch chapter.state {
        case .completed: return .accentColor
        case .running: return .orange
        case .failed: return .red
        case .queued: return .secondary.opacity(0.25)
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
            // Speed — opens the shared horizontal floating picker.
            Button {
                showingRatePicker.toggle()
            } label: {
                Text(player.rate.shortLabel)
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 56, minHeight: 36)
                    .padding(.horizontal, 10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("fullPlayer.playbackRateButton")
            .accessibilityLabel(L10n.string("player.playbackSpeed", player.rate.shortLabel))
            .popover(isPresented: $showingRatePicker, attachmentAnchor: .point(.top), arrowEdge: .bottom) {
                PlaybackRateFloatingPicker(player: player)
                    .frame(minWidth: 340)
                    .padding(.vertical, 8)
                    .presentationCompactAdaptationIfAvailable()
            }

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
                if let snapshot = player.snapshot {
                    let playingEpubIndex = InstantReaderIndexMapper
                        .epubIndex(forPlayableIndex: player.currentChapterIndex, in: snapshot) ?? -1
                    TocDrawer(
                        fulltext: fulltext,
                        snapshot: snapshot,
                        currentChapterIndex: playingEpubIndex,
                        onJump: { epubIndex in
                            if let playable = InstantReaderIndexMapper
                                .playableIndex(forEpubIndex: epubIndex, in: snapshot) {
                                player.play(snapshot: snapshot, startingAt: playable)
                            }
                        }
                    )
                    .compatPresentationDetents()
                }
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
                Image(systemName: playbackClock.sleepTimerRemaining > 0 ? "moon.zzz.fill" : "moon.zzz")
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
            if let snapshot = player.snapshot {
                let playingEpubIndex = InstantReaderIndexMapper
                    .epubIndex(forPlayableIndex: player.currentChapterIndex, in: snapshot) ?? -1
                TocDrawer(
                    fulltext: fulltext,
                    snapshot: snapshot,
                    currentChapterIndex: playingEpubIndex,
                    onJump: { epubIndex in
                        if let playable = InstantReaderIndexMapper
                            .playableIndex(forEpubIndex: epubIndex, in: snapshot) {
                            player.play(snapshot: snapshot, startingAt: playable)
                        }
                    }
                )
                .compatPresentationDetents()
            }
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

    private func dismissPlayer() {
        dragOffset = 0
        playerPresentation.dismissFullPlayer()
        dismiss()
    }

    private func loadLyricsFulltext() async {
        guard let bookID = currentBookID, !bookID.isEmpty else {
            fulltext = nil
            lyricSpans = []
            lyricSentenceId = nil
            return
        }
        let cached = await Task.detached(priority: .utility) {
            LocalFulltextCache.read(bookId: bookID)
        }.value
        fulltext = cached
        prepareLyricsChapter()
    }

    private func prepareLyricsChapter() {
        guard let chapter = currentLyricsChapter else {
            lyricSpans = []
            lyricSentenceId = nil
            return
        }
        lyricSync.load(chapter: chapter, chapterDurationSeconds: playbackClock.durationSeconds)
        lyricSpans = lyricSync.spans
        lyricSentenceId = lyricSync.update(positionSeconds: playbackClock.positionSeconds)
    }

    private var currentLyricsChapter: EbookFulltext.Chapter? {
        guard let fulltext else { return nil }
        let epubIndex: Int
        if let snapshot = player.snapshot,
           let mapped = InstantReaderIndexMapper.epubIndex(
            forPlayableIndex: player.currentChapterIndex,
            in: snapshot
           ) {
            epubIndex = mapped
        } else {
            epubIndex = currentChapterIndex
        }
        return fulltext.chapters.first(where: { $0.index == epubIndex })
    }

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
        player.togglePlayPause()
    }
}

// MARK: - Sleep timer button

/// Inline sleep-timer affordance: tap to cycle through presets, shows
/// remaining time when active (Apple Podcasts pattern).
private struct SleepTimerButton: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var playbackClock: PlaybackClock

    private let presets: [TimeInterval] = [0, 15*60, 30*60, 45*60, 60*60]

    var body: some View {
        Button {
            cycleTimer()
        } label: {
            Label {
                if playbackClock.sleepTimerRemaining > 0 {
                    Text(formatRemaining(playbackClock.sleepTimerRemaining))
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
            playbackClock.sleepTimerRemaining > 0
                ? L10n.string("player.sleepTimerRemaining", formatRemaining(playbackClock.sleepTimerRemaining))
                : L10n.string("player.sleepTimerOff")
        )
    }

    private func cycleTimer() {
        let current = playbackClock.sleepTimerRemaining
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
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var showClearCacheConfirm = false

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
                ToolbarItem(placement: .compatPrimaryTrailing) {
                    Button(role: .destructive) {
                        showClearCacheConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(L10n.string("player.clearChapterCache"))
                    .confirmationDialog(
                        L10n.string("player.clearChapterCache"),
                        isPresented: $showClearCacheConfirm,
                        titleVisibility: .visible
                    ) {
                        Button(L10n.string("settings.clearCacheConfirmButton"), role: .destructive) {
                            if let jobId = player.snapshot?.jobId {
                                AudiobookCacheEviction.deleteAudiobook(jobId: jobId)
                                // The offline copy is gone — clear the
                                // library badge for any book tied to it.
                                for var book in library.books
                                where book.cachedOffline && book.lastJobId == jobId {
                                    book.cachedOffline = false
                                    library.update(book)
                                }
                            }
                        }
                        Button(L10n.string("library.cancel"), role: .cancel) {}
                    } message: {
                        Text(L10n.string("player.clearChapterCacheConfirm"))
                    }
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
        .environmentObject(player.playbackClock)
        .environmentObject(lib)
        .environmentObject(PlayerPresentation())
}
#endif
#endif
