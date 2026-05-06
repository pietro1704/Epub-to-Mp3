---
name: Flutter scaffold 2026-05-06
description: Initial scaffold of flutter_app/ with parity vs iOS slice 3 (jobs list, settings, player+reader, TOC, sync engine)
type: project
---

Scaffolded `flutter_app/` on 2026-05-06 (master) using Flutter 3.41.9
(pinned in `mise.toml`). Targets: android, ios, macos. No web.

**Why:** parity Android against iOS companion (Phase 3 in user task list).

**How to apply:**
- Models live under `lib/models/` and are freezed + json_serializable.
  Regenerate with `mise exec -- dart run build_runner build --delete-conflicting-outputs`.
- `JobSnapshot` and `EbookFulltext` decode the **camelCase** server
  payload directly; `SessionRecord` uses snake_case.
- `SyncEngine` is a line-by-line Dart port of `ios/.../SyncEngine.swift`.
  Keep them in lockstep — algorithm changes go to both.
- Build_runner does NOT process `lib/main.dart` cleanly because Flutter
  3.41 scaffold uses dot-shorthands; we replaced main.dart with custom
  app code so this stops being an issue.
- iOS/macOS native builds need CocoaPods (`brew install cocoapods`) —
  unrelated to code, just environment.
- Android native build needs ANDROID_HOME — unrelated to code.

**Status at scaffold time:**
- `flutter analyze` — 0 issues.
- `flutter test` — 10/10 passing.
- `flutter build apk` — blocked locally on Android SDK absence (env).
- `flutter build ios --no-codesign` — blocked locally on CocoaPods.
