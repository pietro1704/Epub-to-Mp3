# UIKit Performance Migration Plan

> Goal: maximize runtime performance and UI fluidity of the iOS/macOS
> app by replacing most SwiftUI surfaces with UIKit (AppKit on macOS),
> dropping to Swift-with-manual-layout and, where it measurably helps,
> Objective-C / C. SwiftUI is retained only where it costs nothing.

## Hard constraint (read first)

This repo cannot be built or tested inside the current Claude sandbox
(`sandbox_apply` is denied → SwiftPM manifest evaluation fails, so
`xcodebuild` never links). Therefore **every slice below must be
verified on device or in CI**, not in-session. Each slice ships with:

1. A pure, UIKit-free **model layer** with full unit tests (these are
   the only parts verifiable off-device).
2. The UIKit view layer, written compile-correct by inspection, gated
   so a regression is revertible per-slice.

Definition of done per slice = green CI + on-device confirmation
(Instruments: no dropped frames on the target interaction).

## Current state (measured)

- 106 Swift files in `App/` + `Features/` + `Shared/`.
- 46 files `import SwiftUI`; 71 `struct …: View`; ~15.9k lines of View.
- The **reader is already UIKit/TextKit** under the hood: 7
  `UIViewRepresentable`/`UIViewControllerRepresentable`
  (`TextKitPageView`, `AttributedPageView`, `InstantReaderView`,
  `PdfReaderView`, `BookOpenView`, `PlayerView`, `AirPlayPickerView`).
- Remaining perf-sensitive SwiftUI = **scrolling collections** and the
  **player highlight loop**:
  - `LibraryView` (558) + `LibrarySidebar` (278) — `LazyVGrid` book grid
    (already fighting `UIContextMenuInteraction` morph warnings).
  - `ChapterListColumn` (282) / `BookChapterCell` (285) / `TocDrawer`
    (244) — chapter lists.
  - `JobsListView` / `ConversionStatusSheet` — job lists.
  - `FullPlayerSheet` (1086) — continuous lyric/word highlight synced to
    audio (per-frame invalidation is the classic SwiftUI cost).
  - `BookmarksListView`, `ReaderSearchOverlay` — smaller lists.

## Why UIKit here

- `UICollectionView` + compositional layout + diffable data source +
  cell prefetching gives O(visible) work and zero body re-evaluation,
  vs. SwiftUI `LazyVGrid` which re-evaluates the enclosing view tree on
  every `@State`/`@EnvironmentObject` change and pays for identity
  diffing of the whole grid.
- The player highlight is a per-frame animation → a `CADisplayLink`
  driving a `UILabel`/`CATextLayer` mutation is far cheaper than a
  SwiftUI `TimelineView`/`@Published` tick invalidating a 1086-line body.
- macOS gets `NSCollectionView`/`NSViewController` equivalents behind
  the same platform-compat seam already used in `PlatformCompat.swift`.

## Migration order (incremental, host-in-shell first)

The shell stays SwiftUI until the leaves are UIKit; then the shell is
converted last. Never a big-bang rewrite.

### Phase 1 — Collections to UIKit (biggest scroll payoff)
1. **Library grid** → `LibraryCollectionView` (`UICollectionViewController`
   wrapped in a representable). SwiftUI `LibraryView` keeps toolbar/search
   chrome, hosts the UIKit grid. *(slice 1, started)*
2. **Chapter list** (`ChapterListColumn`/`BookChapterCell`) → UIKit list
   config collection view; drives reader navigation.
3. **Jobs list** (`JobsListView`) → UIKit list.

### Phase 2 — Player highlight loop
4. `FullPlayerSheet` lyric/word highlight → `UILabel` + `CADisplayLink`
   driven by the existing `WordTimingResolver`; SwiftUI hosts the bar.
5. `MiniPlayerBar` progress → `UIView`/`CALayer` progress, no per-tick body.

### Phase 3 — Shell to UIKit
6. `SplitViewRoot`/`RootView` → `UISplitViewController` +
   `UINavigationController`; tab/sidebar in UIKit.
7. Sheets (`ReaderSettingsSheet`, `TagEditorSheet`, dialogs) → UIKit
   presentations.

### Phase 4 — Hot-path native code (only if Instruments justifies)
8. Pagination/layout math in `ReaderLayoutMath`/`Paginator` — profile;
   move measured hotspots to tight Swift (no ARC in inner loops) or C.
9. Text measurement / glyph runs — consider Core Text directly and, if a
   loop dominates, a small C shim. Gate behind a benchmark that proves
   the delta; do not rewrite in C speculatively.

## Testability strategy

Because rendering isn't verifiable off-device, each collection slice
splits into:

- `…GridModel` / `…ListModel`: pure struct owning sort/filter/section +
  diffable identifiers (`Hashable` item ids). 100% unit tested.
- `…CollectionView`: thin UIKit layer that only maps model snapshots to
  `NSDiffableDataSourceSnapshot` and configures cells.

The model tests are the CI gate; the UIKit layer is device-verified.

## Rollback

Flags removed once a slice ships. `LibraryCollectionView` is now the
unconditional default on `canImport(UIKit)` (no `USE_UIKIT_LIBRARY_GRID`
env flag) — a regression reverts via `git revert` on the slice's commit,
not a runtime toggle.

## Slice status

- [x] Plan
- [x] Slice 1: Library grid — `LibraryGridModel` + `LibraryGridLayoutMetrics`
      unit-tested; `LibraryCollectionView` is the default renderer on iOS/
      iPadOS (AppKit keeps `LazyVGrid`, no `NSCollectionView` port yet).
- [x] Slice 2: Chapter list — `ChapterListRowModel` unit-tested;
      `ChapterListCollectionView` (list config + diffable data source) is
      the default renderer on iOS/iPadOS in `ChapterListColumn` (AppKit
      keeps the SwiftUI `List`). `BookChapterCell` (continuous-scroll
      chapter *content*, not a list of titles — already TextKit-backed via
      `AttributedPageView`) is intentionally out of scope: it's a rendering
      component, not a list-perf problem, and touching it risks the
      documented `FlickerProbe` regressions.
- [x] Slice 3: Jobs list — `SessionRowModel` unit-tested;
      `JobsListCollectionView` is the default renderer on iOS/iPadOS in
      `JobsListView`, pushing to `JobDetailView` via a
      `navigationDestination(isPresented:)` bridge (AppKit keeps
      `NavigationLink(value:)` + the SwiftUI `List`).
- [x] Phase 2 (progress bars): `PlaybackProgressLayout` unit-tested;
      `PlaybackProgressBar`/`SegmentedPlaybackProgressBar`
      (`CADisplayLink`-driven `CALayer` bars) are the default renderers on
      iOS/iPadOS in `MiniPlayerBar` + `FullPlayerSheet.scrubberBlock`
      (AppKit keeps the SwiftUI `GeometryReader`/`Capsule` bars). The
      per-sentence *lyric text* swap in `FullPlayerSheet` is driven by
      `player.position` (an `AsyncStream`, not a per-frame `@Published`
      tick) and is out of scope for this slice.
- [ ] Phase 3: Shell to UIKit (`SplitViewRoot`/`RootView`, sheets).
- [ ] Phase 4: Hot-path native code — only if Instruments justifies.

## Device verification still pending

Slices 2, 3 and the Phase 2 progress bars above were written compile-correct
by inspection per the hard constraint at the top of this doc — this
sandbox cannot run `xcodebuild`. Each needs on-device confirmation
(Instruments: no dropped frames on the chapter list, jobs list, and
player scrub/expand interactions) before being trusted as a clean win.
