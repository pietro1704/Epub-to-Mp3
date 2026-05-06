# Flutter Companion App — Setup Required

**Status: NOT SCAFFOLDED — Flutter SDK is not installed.**

The scaffolding step was halted because `flutter` is not on PATH. The
companion app cannot be created until the SDK is available locally.

## Prerequisites

Install the Flutter SDK before re-running the scaffold task:

### Option 1 — via mise (preferred for this repo)

The repo uses `mise` for all toolchain management. Add Flutter to
`mise.toml`:

```toml
[tools]
flutter = "stable"
```

Then:

```bash
mise install
mise exec -- flutter --version
```

### Option 2 — official installer

Follow https://docs.flutter.dev/get-started/install/macos and ensure
`flutter` is on PATH:

```bash
flutter --version
flutter doctor
```

## Verifying installation

```bash
which flutter        # should print a path
flutter doctor       # should report Flutter, Dart, and at least one target
                     #   (Android toolchain, Xcode, or macOS desktop) as OK
```

## Re-run the scaffold

Once `which flutter` succeeds, re-issue the scaffold request. The agent
will:

1. `flutter create flutter_app --org com.pietrocode.epubtomp3 --platforms=android,ios,macos`
2. Wire `flutter_riverpod`, `dio`, `freezed`, `just_audio`,
   `shared_preferences`, `flutter_localizations`, `intl`.
3. Build the Settings, Jobs list, and Job detail screens against the
   FastAPI backend (default `http://localhost:8000`).
4. Generate ARB files for `en` and `pt-BR`.
5. Run `dart run build_runner build`, `flutter analyze`, and
   `flutter test` to validate the slice.

## Why this matters for the project

The companion app talks to the same FastAPI server documented in the
root `CLAUDE.md`. Endpoints used by the vertical slice:

- `GET /api/sessions` — jobs list
- `GET /api/jobs/{id}/events` — SSE progress stream
- `GET /api/jobs/{id}/fulltext` — reader mode (future scope)

Backend URL is user-configurable via Settings and persisted with
`shared_preferences`.
