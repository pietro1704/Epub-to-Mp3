# Browser/WASM capability boundary

The current browser path is embedded. The Rails web client
(`ruby_app/rails_gateway`) runs conversion in the browser through
`app/javascript/runtime/conversion_client.js`; the HTTP server is a
compatibility adapter, not an automatic fallback. (The former React client in
`web/` was removed in the Rails cutover; see git history.) `converter-core/Cargo.toml` gates native
process/network dependencies behind `cfg(not(target_arch = "wasm32"))`.

`crates/converter-wasm/src/` exposes EPUB inspection (`inspect_epub`),
`ConversionSession` for Rust-owned segment/provider policy and cancellation, and
`encode_wav_mp3` for bounded PCM WAV encoding through the shared Rust codec.
JavaScript supplies browser I/O, storage and Piper synthesis. Native C ABI
`converter-ffi` is a different adapter; it is not loaded into the browser.

MP3 export requires Piper with explicitly installed, verified
`pt_BR-faber-medium` model assets. Browser system speech is listening-only and
cannot produce downloadable MP3 bytes. The browser adapter rejects unavailable
providers/capabilities; it must not silently switch to HTTP or Edge. Other file
formats and platform capabilities must be checked at the actual adapter rather
than inferred from native core support or product aspirations.

Inspect `conversion_client.js`, `piper_client.js` and `converter_runtime.js` under
`ruby_app/rails_gateway/app/javascript/runtime/`, the Piper worker in
`ruby_app/rails_gateway/browser_runtime/workers/` and the generated runtime tree
(`public/runtime/<id>/`) together when changing this boundary. Generated exports,
model/phonemizer assets and browser storage readiness are separate prerequisites.
Source wiring or an installed WASM target does not establish build, synthesis or
browser acceptance.

Existing tasks include `rails:web:runtime-build` (guarded compilation of the
generated runtime tree) and `rails:web:test` (Rails and browser-runtime tests;
fixture runtime unless `CONVERTER_RUNTIME=built`). Inspect their current
definitions before execution. Use focused web tests with at most two workers and
follow [execution policy](agents/execution-policy.md); a WASM rebuild, dependency
installation or model download is not implicit in a documentation check.
