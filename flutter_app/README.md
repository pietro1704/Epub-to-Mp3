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

Desktop playback registers `just_audio_media_kit` before constructing a player.
Linux and Windows use the bundled media-kit decoder; Android retains its native
player. `AudioPlaybackState` translates decoder readiness, buffering, completion
and `just_audio` errors into the same phase used by the full player, mini-player
and system media controls. A play request alone does not establish playback.
Completion exposes Play again; restarting reopens the decoder before seeking.
Playlist updates use the `just_audio` 0.10 API, preserving progressive chapter
sources. Queued segment updates are serialized and retired when their chapter
is replaced or cleared.

On authorized Arch, the real-decoder regression generates a four-second PCM
tone in a temporary directory and exercises playback, pause/resume, completion,
restart, an invalid replacement and recovery with a new chapter identity:

```sh
mise run flutter:test -- --dart-define=EPUB2MP3_NATIVE_DECODER=true test/linux_audio_backend_integration_test.dart
```

This opt-in test can emit fixture audio. Ordinary tests skip it; it installs no
models and performs no TTS conversion. Windows decoder acceptance and whole-app
conversion/reader journeys remain separate from this Linux playback check.


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
