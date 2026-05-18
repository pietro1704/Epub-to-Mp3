# EpubToMp3 — iOS/macOS SwiftUI app

## Build

```bash
# Recommended — headless, no Xcode UI needed
mise run mac:build          # sidecar:build + xcodebuild → Release .app

# Sidecar only (PyInstaller binary for macOS)
mise run sidecar:build      # → dist/epub-to-mp3-server

# Xcode GUI
xcodegen generate           # regenerate .xcodeproj from project.yml
open EpubToMp3.xcodeproj
```

`mise run mac:build` chains `sidecar:build` then `xcodebuild -scheme EpubToMp3 -configuration Release`. The resulting `.app` is at `ios/EpubToMp3/.build/Build/Products/Release/EpubToMp3.app`.

## Targets

| Target | Type | Deployment | Bundle ID |
|---|---|---|---|
| `EpubToMp3` | Application | iOS 15.0 / macOS 12.0 | `com.pietrocode.epubtomp3` |
| `EpubToMp3Widget` | App Extension | iOS 17.0 | `com.pietrocode.epubtomp3.widget` |
| `EpubToMp3ShareExtension` | App Extension | iOS 15.0 | _(in `EpubToMp3ShareExtension/`)_ |
| `EpubToMp3Tests` | Unit Test Bundle | iOS 15.0 / macOS 12.0 | — |

The `EpubToMp3Widget` target requires iOS 17+ because it uses `.containerBackground` (WidgetKit API added in iOS 17).

## App Group

`group.com.pietrocode.epubtomp3`

Used by the main app (`LibraryStore`, `SharedContainerImporter`, `WidgetDataSync`) and `EpubToMp3Widget` to share `UserDefaults` state (now-playing book ID, chapter index, progress, cover art).

## Shared types

`EpubToMp3/Models/ConversionActivityAttributes.swift` is compiled into **both** `EpubToMp3` and `EpubToMp3Widget`. ActivityKit serialises by name + Codable — the struct must be bit-for-bit identical in both targets. Do not move or rename it without updating `project.yml`.

## Widgets

| Widget | Kind | Surface |
|---|---|---|
| `NowPlayingWidget` | `NowPlayingWidget` | Home screen (medium / large) |
| `NowPlayingLockScreenWidget` | _(lock)_ | Lock screen |
| `ConversionLiveActivityWidget` | Live Activity | Dynamic Island + lock-screen banner |

## Key features (post immersive-reader sprint)

- **Immersive reader** — tap centre of page to toggle chrome (nav bar + status bar). Auto-hides on page turn. Shared `ChromeVisibilityModifier` in `InstantReaderView` and `PlayerReaderView`.
- **No-autoplay policy** — audio never starts without an explicit user gesture (lock-screen controls, widget Play, or in-app Play button).
- **Live Activity** — `ConversionLiveActivityWidget` pushes chapter progress to Dynamic Island and lock-screen banner during active conversions.
- **Haptic scrubber** — timeline scrub in `NowPlayingView` triggers `.selectionChanged` haptic feedback.
- **Bookmark guard** — prevents duplicate bookmarks on the same chapter offset.
- **Landscape reader** — page layout adapts to landscape without chrome overlap.

## Entitlements

| Config | File | Notes |
|---|---|---|
| Debug (macOS / Simulator) | `EpubToMp3-Debug.entitlements` | App Sandbox disabled; security-scoped bookmarks still listed for iOS device builds |
| Release | `EpubToMp3.entitlements` | Hardened Runtime + App Sandbox enabled |

macOS local Debug builds use unsigned code (`CODE_SIGN_IDENTITY = "-"`). iOS device Debug builds require `Apple Development` signing; the Release config uses Automatic.

## Project file

`project.yml` is the source of truth for Xcode project structure (xcodegen). Run `xcodegen generate` after editing it. Never edit `.xcodeproj` directly.
