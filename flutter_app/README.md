# Flutter client

Flutter owns the Linux, Windows and Android client. Apple clients live in
`ios/EpubToMp3/` and use native UIKit/AppKit. Shared conversion behavior belongs
in Rust, with platform adapters for UI, files, speech and playback.

`lib/main.dart` registers `AndroidEmbeddedConverter` on Android and
`DesktopEmbeddedConverter` on Linux/Windows before providers resolve the runtime.
`lib/services/embedded_converter.dart` defines the seam; desktop uses direct
`converter-ffi`, Android uses its registered native platform channel/JNI path.
`RustPlaybackConversionService` handles the moving Listen window over that seam.
The retained `api_client.dart`, Python bridge source/assets and backend settings
are compatibility surfaces, not proof that normal local conversion uses HTTP or
Python. Missing native artifacts are explicit failures, not permission to select
a different backend silently.

## Development and platform ownership

Read [execution policy](../docs/agents/execution-policy.md) and inspect
`mise.toml`, `pubspec.yaml` and platform packaging scripts before execution.
Android work remains paused until the user resumes it. Android/Samsung and
Flutter Linux builds/tests/artifacts belong on Arch; Windows packaging needs a
compatible Windows toolchain. Do not start an Android emulator from a general
quickstart or run Flutter builds on this Mac as a diagnostic shortcut.

Existing tasks include `flutter:test`, `flutter:analyze`,
`flutter:build-apk-debug`, `flutter:build-apk`, `flutter:build-linux` and
`flutter:build-windows`. Availability is not authorization or evidence of passing
results. Android build tasks depend on native FFI installation; desktop tasks own
their platform packaging. Inspect before invoking; no Python bootstrap is a
production prerequisite.

## Application seams

- `lib/state/providers.dart`: runtime and state composition.
- `lib/services/local_conversion_job.dart`: local history from Rust manifests.
- `lib/services/audio_player_service.dart`: playback and progressive sources.
- `lib/services/resume_store.dart`: persisted playback position.
- `lib/services/desktop_tts_model_adapter.dart`: shared model catalog/store adapter.
- `lib/l10n/`: locale resources; keep intended locale values literal.

Piper `pt_BR-faber-medium` remains primary, with installed system TTS fallback
where supported, explicit active voice reporting and bounded Piper recovery.
Explicit job choices win. Edge requires consent; model installation requires an
explicit action. Tests should exercise registered runtime behavior, success and
relevant error/cancellation/book-chapter identity. Source registration alone does
not establish device, audio, packaging or release acceptance.

See [behavior map](MIRROR-MAP.md) for cross-client ownership and historical
`PYTHON-EMBED-*` paths for compatibility context, not current setup recipes.
