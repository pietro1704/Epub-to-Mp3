# Apple and Flutter behavior map

This map describes ownership and review seams, not a synchronization receipt.
The historical 2026-05-11 SwiftUI/Dart table and its SHA/status values are retained
in the guide archive. They do not establish current parity or authorize a queue
consumer to edit, commit or run another platform automatically.

Shared conversion behavior belongs in `crates/converter-core/` and is exposed
through `converter-ffi`, CLI and WASM adapters. Native Apple and Flutter UI remain
idiomatic; copying Swift view files into Dart is not the parity strategy.

| Concern | Apple starting point | Flutter starting point | Shared contract |
| --- | --- | --- | --- |
| Conversion | `RustConversionCoordinator.swift`, `ConverterFFIAdapter.swift` | `lib/services/embedded_converter.dart`, `desktop_embedded_converter.dart` | Rust jobs, provider policy, cancellation, chapter/artifact identity |
| Listen window | `Features/Playback/Services/AudioPlayer.swift` | `lib/services/rust_playback_conversion.dart`, `audio_player_service.dart` | Ordered chapter chunks, explicit playback, cancellation |
| Library/resume | `Features/Library/Services/LibraryStore.swift` | `lib/services/resume_store.dart`, library state under `lib/` | Stable source/book/chapter identity and persisted position |
| Provider/model settings | Apple conversion/settings services | `lib/services/desktop_tts_model_adapter.dart`, `tts_model_adapter_registry.dart` | Shared catalog/preferences, explicit installation and consent |
| Optional HTTP compatibility | Locate actual API client callers | `lib/services/api_client.dart` | Current wire schema, only for explicitly selected compatibility use |

Apple paths are relative to `ios/EpubToMp3/EpubToMp3/`; locate current callers with
`rg` before changing them. A matching type name or old synchronized SHA cannot
prove behavioral parity. Validate the affected seam, including relevant errors,
cancellation and cross-book/chapter identity; record platform differences and
unexecuted checks. Preserve useful platform behavior rather than forcing pixel,
gesture or Apple API parity.

Follow [execution policy](../docs/agents/execution-policy.md): Android remains
paused and Android/Flutter Linux work belongs on Arch. Cross-client review does
not authorize another platform's build, device actions or automatic commits.
