# Build/cache cleanup and monitoring — 2026-07-26

## Scope

This session concerned development artifacts around the repository, not the
runtime caches used by the shipped iOS/macOS app. Runtime cache policy changes
were reverted after that distinction was clarified.

## Measured artifacts

Before cleanup, the following regenerable artifacts were present:

- `ios/EpubToMp3/.build`: 432 MB
- `ios/EpubToMp3/.build-device`: 455 MB
- `ios/EpubToMp3/.build-fallback-parser`: 152 MB
- `ios/EpubToMp3/.build-fallback-parser-final`: 181 MB
- `ios/EpubToMp3/.build-sleep-timer`: 583 MB
- `ios/EpubToMp3/.build-tests`: 581 MB
- `ios/EpubToMp3/.build-tests-2`: 231 MB
- `ios/EpubToMp3/Build`: 8 MB
- `build`: 178 MB
- `dist`: 130 MB
- `flutter_app/build`: present and regenerable
- `web/dist`: 632 KB
- `/Applications/EpubToMp3.app`: 344 MB

The repository had 26 GiB available before cleanup. The listed artifacts were
moved to the user's Trash, not permanently deleted, so they remain recoverable
and still count against disk usage until the Trash is emptied.

The follow-up scan also moved these Xcode caches to Trash:

- project-specific `EpubToMp3-*` DerivedData: 2.2 GB;
- global `ModuleCache.noindex`: 2.3 GB;
- global SDK and symbol caches: approximately 74 MB.

The mise cache was only 12 KB and was left in place. CoreSimulator caches were
empty. The global Xcode caches are regenerable but can affect other projects;
they were removed only because this cleanup explicitly targeted maximum local
development-space recovery.

## Changes retained

- `mise.toml` now exposes `mise run ios:test`.
- It prefers an available physical iPhone.
- It falls back to `ios:simulator:test` only when no physical device is
  available.
- The device test task exports `DD` correctly to its child shell.
- The project is regenerated from `project.yml` before Apple tests.

## Changes intentionally reverted

The temporary attempt to add automatic quotas for fulltext/TTS runtime caches
was reverted. It was outside this request and would have changed app behavior.
Existing app runtime cache policy remains unchanged.

## Monitoring rules

- Never run concurrent Xcode jobs against one DerivedData directory.
- Stream verbose output and inspect timestamps, child processes, CPU, RAM, and
  build database locks.
- Stop a build/test when it has no meaningful progress or an actionable error
  appears; fix that issue before resuming.
- After an interrupted valid task, resume it automatically using the existing
  cache instead of waiting for another user prompt.
- After user-run Xcode builds, analyze logs and propagate performance findings
  to the relevant planning, testing, QA, and toolchain agents.
- Preserve source, user inputs, `.cache/`, `output/`, models, and active
  artifacts unless the user explicitly authorizes their removal.
