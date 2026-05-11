---
name: Flutter platforms scope
description: flutter_app/ targets Linux + Windows + Android only; macOS/iOS belong to the SwiftUI app
type: project
---

The Flutter companion ships for **Linux + Windows + Android** only.

**Why:** macOS and iOS are covered by the SwiftUI app at `ios/EpubToMp3/`
(Library-first reader, embedded Python sidecar on macOS). Maintaining
two Apple clients would duplicate work and split product polish. User
ratified this on 2026-05-10 and asked for all references corrected.

**How to apply:**
- Never run `flutter create ... --platforms=...,ios` or `...,macos`.
- Never re-introduce `flutter_app/ios/` or `flutter_app/macos/`
  scaffolds (both were deleted 2026-05-10).
- Never add a `flutter:build-ios` / `flutter:build-macos` task to
  `mise.toml`.
- In release CI (`.github/workflows/release-desktop.yml`), the
  `flutter-desktop` matrix is `linux-x64 + windows-x64` only; do not
  add a macOS runner.
- When mirroring features across mobile clients, "mobile" means
  **SwiftUI (iOS/iPad) + Flutter (Android)** — not "SwiftUI + Flutter
  on iOS".
- `cocoapods` stays in `mise.toml` because the Capacitor iOS build
  under `web/ios/App/` uses it — NOT Flutter.
