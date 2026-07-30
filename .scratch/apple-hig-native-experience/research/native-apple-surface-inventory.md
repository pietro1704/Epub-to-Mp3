# Native Apple Surface Inventory

Scope: repository inspection only, 2026-07-30. Sources below are primary
project sources; no app code, ticket, or map was changed.

## Platform roots and ownership

| Platform | Root composition | Owner boundary |
| --- | --- | --- |
| iPhone/iPad | `IOSSceneDelegate` creates `IOSRootContainerController`; it embeds a three-tab `IOSAppShellController`, the reader overlay, mini player, and full-player overlay. | `IOSRootContainerController` owns cross-surface visibility/constraints; feature controllers own their local content. |
| macOS | `EpubToMp3App` creates one `NSWindow` with `MacAppKitRootController` as `NSSplitViewController`. | `MacAppKitRootController` owns sidebar, detail replacement, persistent bottom player and full-player overlay. |
| Shared | `EpubToMp3App` owns `AppSettings`, `LibraryStore`, `AudioPlayer`, `PlayerPresentation`, and `BookmarkStore`. | Services/models are shared; UIKit and AppKit views are separate implementations. |

Sources: `App/IOSSceneDelegate.swift`, `App/IOSRootContainer.swift`,
`App/IOSAppShell.swift`, `App/EpubToMp3App.swift`,
`App/MacAppKitRootController.swift`.

## iOS and iPadOS surfaces

| Surface | Controller / owner | Current native behavior | Planning-relevant deviation or risk |
| --- | --- | --- | --- |
| App shell | `IOSAppShellController` | `UITabBarController` with Library, Settings, Convert; each tab has its own `UINavigationController`. | iPad uses the exact iPhone tab composition; no split/sidebar or size-class-specific navigation architecture exists. |
| Library | `LibraryScreenController` → `LibraryGridController` | Navigation search, menu actions, document picker, compositional grid, context menu. | Grid metrics are width-adaptive, but navigation and presentation are not iPad-specialized. Opening a book bypasses a visible book-detail transition by setting global `ReaderSessionState`. |
| Book detail | `BookDetailScreenController` | Push surface for metadata, reading/listening/download actions. | Needs audit against the direct-open library route so duplicate/competing paths are intentional. |
| Reader host | `MainReaderScreenController` under `IOSRootContainerController` | Root-level overlay takes reader out of tab navigation; host installs an iPhone-style navigation bar. | Overlay lifecycle and bottom constraints are separate from the tab/navigation controller hierarchy. This is the highest layout-regression risk for tab bar, mini player, loading, rotation, and presentation state. |
| Reading surface | `BookOpenScreenController` | `UITextView` plus manual paginated offsets or scrolling; TOC/settings/search in host navigation bar; custom immersive tap; PDF path via `PDFView`. | Paginated mode is a custom non-scrolling `UIScrollView`, not a UIKit paging controller. It needs device/rotation/Dynamic Type/VoiceOver validation before HIG planning. Chrome is manually hidden rather than driven by a standard reader container. |
| Reader sheets | `TocSheetController`, `FootnotesSheetController`, `ReaderSettingsScreenController` | Navigation-wrapped sheets; TOC manages per-chapter downloads. | Sheet detents are set only at select call sites; iPad popover/compact presentation behavior requires surface-by-surface verification. |
| Mini player | `MiniPlayerContainerController` → `MiniPlayerBarUIKitView` | Root overlay above tab bar; entire non-control pill opens full player; iOS 26 uses `UIGlassEffect`, older OS uses blur. | It is custom chrome with its own safe-area and root constraints. Its current shape/height/placement must be validated in compact, landscape, iPad, Dynamic Type, and keyboard states. |
| Full player | `FullPlayerScreenController` | Root overlay with custom drag-dismiss, controls, cover, scrubber, TOC sheet, AirPlay/volume. | Custom presentation rather than a standard sheet/controller presentation; HIG behavior needs direct real-device validation, especially modal accessibility and dismissal. |
| Conversion | `ConvertScreenController`, `JobsListScreenController`, `JobDetailScreenController`, `PlayerScreenController` | Table-based conversion/job flows and document picker. | Conversion appears as a top-level tab alongside content rather than a platform-specific workflow; validate hierarchy and task prominence. |
| Settings/diagnostics | `SettingsScreenController`, `TelemetryScreenController`, `LogsScreenController` | `UITableViewController` forms and push detail screens. | Mostly native primitives, but choices use alerts/action sheets; iPad popover anchoring and destructive-action flows require audit. |
| External integrations | `CarPlaySceneDelegate`, widget/Live Activity, share extension | Audio background mode, CarPlay, document opening, widget/deep-link hooks. | These are separate user surfaces; strict HIG scope must explicitly include or defer them. |

Sources: `Features/Library/Views/*.swift`, `Features/Reader/Views/*.swift`,
`Features/Playback/Views/*.swift`, `Features/Conversion/Views/*.swift`,
`Features/Settings/Views/*.swift`, `Resources/Info.plist`.

## macOS surfaces

| Surface | Controller / owner | Current native behavior | Planning-relevant deviation or risk |
| --- | --- | --- | --- |
| Window and navigation | `EpubToMp3App` → `MacAppKitRootController` | Programmatic `NSWindow`, native `NSSplitViewController.sidebar`, custom titlebar sidebar button. | One manually assembled window/menu; no command/menu architecture beyond Quit. Keyboard shortcuts, menu commands, window restoration, and toolbar semantics need an explicit decision. |
| Sidebar | `MacAppKitRootController.makeSidebar()` | Custom `NSStackView`/`NSButton` navigation for Library, Jobs, Settings. | It is visually/custom behavior rather than `NSToolbar`/sidebar list patterns. Sidebar toggle was recently repaired; keep its behavioral regression test. |
| Library | `MacLibraryViewController` and `MacBookDetailViewController` | Search field, collection view, details, alerts. | Separate from UIKit but feature parity and native selection/double-click/context-menu behavior require audit. |
| Reader | `MacReaderViewController` | Custom toolbar, `NSTextView`, TOC/settings popovers, `NSAlert` footnotes, loading overlay, PDF display. | Source class currently does not declare `NSTextViewDelegate` or assign `textView.delegate`; internal `epub-link` footnotes can escape to Launch Services instead of opening in-app. This is a correctness blocker, not only polish. |
| Bottom mini player | private `MacPlayerBarViewController` | Persistent bar in detail container, shown when reader has context. | Custom height and placement tied to detail constraints; no system-standard mini-player container exists, so layout/accessibility needs visual validation across window sizes. |
| Full player | private `MacFullPlayerViewController` | Overlayed full-player mode driven by `PlayerPresentation`. | Custom modal semantics; needs keyboard focus, Escape, VoiceOver, resizing/full-screen validation. |
| Jobs/settings | `MacJobsListViewController`, `MacSettingsViewController` | AppKit table/control surfaces. | Mac implementation is intentionally narrower than iOS diagnostics/settings; feature parity versus platform-appropriate scope must be decided. |

Sources: `App/MacAppKitRootController.swift`, `App/EpubToMp3App.swift`,
`Features/Library/Views/Mac*.swift`, `Features/Reader/Views/MacReaderViewController.swift`,
`Features/Conversion/Views/MacJobsListViewController.swift`,
`Features/Settings/Views/MacSettingsViewController.swift`.

## Shared services; do not collapse the view layer

- Content/import: `LibraryStore`, EPUB/PDF readers, `FulltextStore` and local
  cache own book data and parsed full text.
- Reading: `EbookFulltext`, `ReaderLinkResolver`, `ReaderPaginatedTextLayout`,
  `ReaderProgressStore`, and `ReaderSessionState` are platform-neutral
  reading services/state.
- Playback: `AudioPlayer`, `PlaybackClock`, `PlaybackRouter`,
  `PlayerPresentation`, download/cache services own audio state; every visual
  player observes them.
- Conversion: embedded Python bridges/coordinator and API job view models own
  conversion, not a platform view.

Constraint: preserve these boundaries. HIG work should replace/adapt UIKit or
AppKit composition independently, not make one platform's controller the
other's view implementation.

Sources: `Features/{Library,Reader,Playback,Conversion,Offline}/Services`,
`Features/Reader/Models`, `Features/Playback/Models`, `Shared/Configuration`.

## Constraints for the map

1. Deployment targets are iOS 15 and macOS 12, while the product priority is
   iOS 26. Modern effects must be availability-gated; `AdaptiveMaterialView`
   already uses `UIGlassEffect` only on iOS 26 and blur otherwise.
2. iPhone/iPad support portrait and landscape, indirect input, audio
   backgrounding, document-in-place and single-scene lifecycle. The map needs
   a real-device matrix rather than assuming iPhone layouts generalize to iPad.
3. UIKit and AppKit are deliberately separate and macOS is native AppKit (not
   Catalyst); no shared layout abstraction should be introduced merely for
   visual parity.
4. The reader, mini player and full player are root overlays. Any navigation,
   safe-area, tab-bar or scene change must test the composed root, not just an
   isolated view controller.
5. Existing automated UI coverage is iOS-only; macOS coverage is largely
   source/unit-level. Strict visual HIG acceptance therefore requires manual
   macOS validation plus new behavior tests where feasible.
6. The repository contains custom `epub-link` rendering and a shared resolver.
   iOS intercepts it through `UITextViewDelegate`; macOS must gain equivalent
   interception before any HIG visual pass can claim the reader is native.

Sources: `project.yml`, `Resources/Info.plist`, `App/IOSRootContainer.swift`,
`App/IOSSceneDelegate.swift`, `Features/Reader/Services/ReaderLinkResolver.swift`,
`Features/Reader/Services/EpubHtmlRenderer.swift`,
`Features/Reader/Views/BookOpenScreenController.swift`,
`EpubToMp3Tests/`, `EpubToMp3UITests/`.
