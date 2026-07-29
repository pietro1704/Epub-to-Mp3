# Codex working memory

Operational notes for collaborating on this repository with the owner.

## Collaboration preferences

- Respond in concise pt-BR and act on bug reports immediately.
- For non-trivial work, use the portable agent pipeline: inspect, plan, implement, verify, critic pass, then test.
- Scope changes explicitly. The current request often targets UIKit/iOS only; do not touch Flutter unless requested.
- After every iOS code batch, build with the existing Xcode cache, install on the real iPhone, launch in the foreground, and attach LLDB.
- Do not use an iOS Simulator on the Intel Mac. Physical-device validation is preferred.
- Do not commit or push unless requested in the current task.

## iOS device workflow that works

Device used during validation:

- CoreDevice ID: `44B2CFBD-2193-5086-8E8D-BF7A2876C321`
- LLDB device UDID: `00008140-001128A022BA801C`
- Bundle ID: `com.pietrocode.epubtomp3`

Build:

```bash
xcodebuild -project ios/EpubToMp3/EpubToMp3.xcodeproj \
  -scheme EpubToMp3 -configuration Debug \
  -destination 'id=00008140-001128A022BA801C' \
  -derivedDataPath ios/EpubToMp3/.build build
```

Install/launch:

```bash
xcrun devicectl device install app \
  --device 44B2CFBD-2193-5086-8E8D-BF7A2876C321 \
  ios/EpubToMp3/.build/Build/Products/Debug-iphoneos/EpubToMp3.app
xcrun devicectl device process launch \
  --device 44B2CFBD-2193-5086-8E8D-BF7A2876C321 \
  --terminate-existing com.pietrocode.epubtomp3
```

Attach LLDB after finding the process with `devicectl device info processes`:

```text
lldb
device select iPhone
device process attach -p <pid>
process status
```

The iPhone must be unlocked. `idevicescreenshot` failed in this environment because its screenshotr service was unavailable; use a user-provided screenshot when visual inspection is needed.

## iOS lessons from this project

- The reader is UIKit/AppKit, not SwiftUI. EPUB HTML/CSS rendering must remain untouched when changing reader chrome.
- The reader defaults to paginated mode. `PageTurnStyle` is persisted in `AppSettings`; `.none` is presented as Normal, `.slide` as Deslizar, and `.flip` as Virar.
- Loading must hide the mini player and use the reader's full available height.
- Hidden chrome needs paired active constraints. When the top navigation bar is hidden, reader content must switch from the navigation-bar top anchor to the root top anchor; otherwise a blank top gap remains.
- A container with only leading/trailing/bottom constraints has no useful intrinsic height. The mini player expanded over the whole reader until `MiniPlayerBarUIKitView.preferredHeight` was constrained in `IOSRootContainerController`.
- An empty multiline `UILabel` in a vertical `UIStackView` can absorb unexpected height on iOS 26. Keep status labels out of the main reader stack unless they have explicit sizing.
- A hidden navigation-bar custom view can still reserve a blank circular item. Remove the bar item instead of setting only `isHidden`.
- HIG touch targets are at least 44x44 pt, with accessible labels/values. Keep toolbar spacing explicit but let the content scroll view be the only flexible vertical element.
- Theme cells use a visual color preview; TOC rows use local download truth from `DownloadManager`, not merely a server `downloadUrl`.
- When inspecting UI work, activate iPhone Mirroring and capture the mirrored screen; do not rely only on source constraints or an assumed visual result.
- For the mini player, the material/background may extend to the physical screen bottom, while the horizontal control stack must end exactly at the mini view's safe-area bottom.
- Avoid a fixed mini-player height when possible. Use leading/trailing/top/bottom constraints, 44 pt control sizing, content hugging/compression resistance, and an intrinsic height derived from the stack plus the safe-area inset. Removing the height constraint without providing intrinsic height makes the mini player expand over much of the reader.
- Tapping the mini-player image, title, chapter text, or empty bar area opens the full player. Control buttons must remain excluded from that expansion gesture.

## Storyboard migration lesson

- The app currently builds its dynamic reader layout in Swift. A hand-authored `ReaderLayout.storyboard` attempt did not compile with this Xcode 26 `ibtool`, despite well-formed XML, and was removed so the target remained green.
- Do not reintroduce a storyboard bridge without validating it with `ibtool` first. If storyboard editing is still desired, migrate one stable container at a time using a storyboard created/saved by Xcode, then keep EPUB rendering and dynamic state in controllers.

## Git and safety

- Preserve unrelated user changes and do not use destructive resets.
- Generated `ios/EpubToMp3/.build` is an intentional active cache; do not delete it during normal iteration.
- Before commit: `git diff --check`, verify only requested surfaces changed, and run the relevant build/tests. After a requested push, monitor CI.
