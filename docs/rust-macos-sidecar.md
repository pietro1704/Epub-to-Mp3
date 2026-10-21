# Standalone Rust server reference (historical sidecar name)

Apple production clients use native UIKit/AppKit and embedded
`converter-core`/`converter-ffi`. They do not require a local HTTP server or a
remote backend for their embedded conversion path. See
[runtime navigation](agents/runtime-navigation.md) and
[Apple client guide](../ios/EpubToMp3/README.md).

The historical `sidecar:build` task remains in `mise.toml`: it builds the separate
`converter-server` executable and copies it to `dist/epub-to-mp3-server`.
`mac:build` instead depends on `converter-ffi:build`; presence of a server artifact
does not mean Xcode embeds or launches it. Use the standalone task only for a
specifically requested server/compatibility use case after inspecting its current
source and the [execution policy](agents/execution-policy.md).

Server configuration, endpoints, persistence and bind addresses belong to
`crates/converter-server/src/main.rs`, `converter-core` configuration and the
current container manifests. Inspect those before exposing a server; old port
`47860` and sidecar-lifecycle recipes are historical details, not Apple defaults.
No server, app or service was exercised merely by documenting this boundary.
