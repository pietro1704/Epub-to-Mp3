# iOS Feature Architecture Organization Plan

**Goal:** Organize the iOS/macOS Swift target by feature ownership while preserving current behavior, target membership, source-contract tests, and the existing SwiftUI/UIKit split.

**Architecture:** Use feature-first directories with local `Views`, `Models`, and `Services` only where those boundaries are real. Keep SwiftUI as the composition shell, UIKit/TextKit/UIPageViewController for document-rendering hot paths, and the existing `ConvertViewModel`/`JobsListViewModel` as the only ViewModels unless a new state boundary is demonstrated by tests.

**Sources consulted:**

- Apple, “Model data”: https://developer.apple.com/documentation/swiftui/model-data
- Apple, “View controllers”: https://developer.apple.com/documentation/uikit/view-controllers
- Point-Free, “The Composable Architecture”: https://github.com/pointfreeco/swift-composable-architecture

## Target layout

```text
ios/EpubToMp3/EpubToMp3/
├── App/
│   ├── EpubToMp3App.swift
│   ├── PlatformCompat.swift
│   ├── PreviewFixtures.swift
│   ├── RootView.swift
│   └── SplitViewRoot.swift
├── Features/
│   ├── Conversion/
│   │   ├── Models/       JobSnapshot, ConversionStatus, SessionRecord
│   │   ├── Services/     APIClient, Python*, SidecarManager, watchdog, TTS bridges
│   │   └── Views/        ConvertView, JobsListView, JobDetailView, status sheet
│   ├── Library/
│   │   ├── Models/       BookEntity, BookChapterProgress, Bookmark
│   │   ├── Services/     LibraryStore, BookmarkStore
│   │   └── Views/        Library screens and import/drop components
│   ├── Offline/
│   │   └── Services/     DownloadManager, fulltext/cache/eviction/shared-container
│   ├── Playback/
│   │   ├── Models/       PlaybackTargetResolver
│   │   ├── Services/     AudioPlayer, clock, router, presentation, speech/audio
│   │   └── Views/        player surfaces and AirPlay controls
│   ├── Reader/
│   │   ├── Models/       EbookFulltext, reader anchors and choice resolver
│   │   ├── Services/     ReaderCoordinator, paginator, HTML/font/render settings
│   │   └── Views/        reader hosts, TextKit/UIKit surfaces, TOC and reader UI
│   └── Settings/
│       ├── Services/     sync and widget integration
│       └── Views/        settings, logs, telemetry and tag editor
└── Shared/
    ├── Concurrency/      AsyncTimeout
    ├── Integrations/     App intents, widgets, shared ActivityKit model
    ├── Localization/     L10n
    └── Configuration/    AppSettings
```

## MVC/MVVM boundary rules

1. SwiftUI views render state and emit user intents; they should not become generic “ViewModel” dumping grounds.
2. `ConvertViewModel` and `JobsListViewModel` remain feature-local MVVM because they own async submission/loading state and are independently testable.
3. `LibraryStore`, `AudioPlayer`, `ReaderCoordinator`, and cache/download managers remain domain services/state owners; renaming them to ViewModels would obscure ownership.
4. `ReaderView` keeps local transient pagination/gesture state. Its UIKit wrappers remain rendering adapters, not ViewModels.
5. `RootView`/`EpubToMp3App` remain composition and dependency-injection boundaries.
6. No C migration is part of folder organization. C is considered only after a reproducible profile identifies a CPU-bound Swift hotspot and a benchmark shows a net win after bridging.

## Execution and verification

- Move source files with reversible `git mv` operations; do not modify behavior in the organization pass.
- Update `project.yml` only for targets that explicitly reference a moved shared file (`SharedContainerInbox` and `ConversionActivityAttributes`).
- Update source-contract test paths instead of allowing tests to skip because a file moved.
- Regenerate with `mise exec -- xcodegen generate`.
- Run focused reader/library/conversion tests, then the complete macOS host suite and generic iOS build.
- Verify `git diff --check`, target membership, no duplicate Swift files, and no source-contract test skips caused by path changes.