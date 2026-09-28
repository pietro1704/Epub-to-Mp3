# Browser/WASM capability boundary

The Rust converter currently has two different portability surfaces:

- `converter-core` contains the EPUB reader, but the crate also includes the
  native conversion pipeline, filesystem/process access, and network/TTS
  dependencies. It is not a browser-WASM crate.
- `converter-ffi` is a native C ABI for local-file metadata sessions. It is
  intended for native iOS/Android/macOS integrations and is not a browser
  adapter.

The web client therefore remains in compatibility mode: full MP3 conversion
continues to use the existing HTTP API. No browser path claims to perform
embedded conversion.

A safe future browser slice should be a separate, deliberately small crate
(or a TypeScript worker implementation) that accepts EPUB bytes and exposes
only metadata and bounded chapter text previews. It must not depend on TTS,
audio codecs, filesystem paths, process spawning, sockets, or HTTP clients.
Its conversion entrypoint should return a typed unavailable error rather than
silently falling back to a different backend.

## Validation

Run the repository's web gate with:

```sh
mise run test:web
```

The current Rust target check is intentionally not part of production web
builds. `converter-core` does not compile for `wasm32-unknown-unknown` as a
whole because its native-only dependencies and APIs are mixed into the crate.
The local Rust installation may report an installed WASM target while still
being unable to link/check this crate; that is not evidence of browser
portability.
