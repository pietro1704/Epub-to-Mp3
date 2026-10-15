# Codex working memory

Operational notes for collaborating on this repository with the owner.

## Current sources of truth

This file retains historical native UI lessons only. Current collaboration,
language, Gitflow, authorization and test rules live in `../AGENTS.md`
(the alias of `../CLAUDE.md`), `../CODING_STANDARDS.md` and
`agent-workflow.md`. The native reader contract is
`../ios/EpubToMp3/AGENTS.md`.

Durable cross-session knowledge belongs in ai-memory, scoped by the repository
`.ai-memory.toml`; use its managed skills under `.agents/skills/ai-memory-*`.
Historical notes cannot override current instructions. Physical-device-only
validation, a blanket Intel Simulator ban, manual device IDs, automatic LLDB
attachment and automatic CI monitoring from older notes are superseded.
Reader verification uses the exact SE1/iOS 15.5 and native macOS targets with
the build/Simulator phase separation in `agent-workflow.md`.

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
- Before commit: `git diff --check`, verify only requested surfaces changed, and run the relevant build/tests. CI/PR monitoring is opt-in under the current project instructions.
