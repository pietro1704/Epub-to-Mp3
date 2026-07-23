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

Each slice keeps the SwiftUI implementation behind a compile flag
(`USE_UIKIT_<surface>`, default on once device-verified) for one release
so a perf/behavior regression is a one-line revert, not a re-migration.

## Slice status

- [x] Plan
- [~] Slice 1: Library grid — `LibraryGridModel` + tests landed; UIKit
      collection view layer next.
- [ ] Slice 2+: per list above.
