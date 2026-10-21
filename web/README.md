# Web frontend

React/TypeScript/Vite UI with an embedded Rust/WASM conversion path.
`src/services/ConversionService.ts` exports `BrowserConversionClient`, backed by
`src/wasm/`, browser Piper synthesis and browser storage. Retained HTTP and mock
clients are separate adapters; do not infer Python backend dependence or HTTP
fallback from their presence.

## Local development

Inspect `package.json`, `mise.toml` and the
[execution policy](../docs/agents/execution-policy.md) before running tasks.
With existing managed tools/dependencies, from `web/`:

```sh
mise exec -- npm run dev
mise exec -- npm run lint
mise exec -- npm run test -- --maxWorkers=2
mise exec -- npm run build
```

The `predev`/`prebuild` scripts prepare browser TTS assets; inspect their current
inputs when diagnosing a missing artifact. A Rust/WASM rebuild uses the guarded
`web:wasm-build` task, not a direct compiler command. Start tests with at most two
workers. The broad `test:web` task currently has a legacy Python-install precheck;
inspect it before use, since local Python execution remains deferred to CI.
Dependency installation, model downloads and service startup require appropriate
scope; they are not implicit in a documentation or source inspection.

## Capabilities and providers

The browser adapter inspects EPUB and uses Rust `ConversionSession` for segment
ordering, policy, cancellation and accepted audio. Piper `pt_BR-faber-medium`
requires explicit model installation and verification. Browser system speech is
listening-only; MP3 export requires Piper. Edge/other unavailable browser
providers must fail explicitly rather than switch to an HTTP server. Check the
actual adapter before claiming PDF or native-only format support.

## Queue EPUB files

1. Add supported EPUB files in the upload step. Use drag or order controls to
   reorder pending books before starting conversion.
2. Start the queue to process books sequentially with the selected provider
   configuration. Model installation remains a separate explicit action.
3. During progress, add more EPUB files through the queue control; they follow
   the current conversion. Use the existing progress, cancel and playback controls.

Batch queue UI, progress, chapter playback and stored jobs must be verified at
the browser runtime when changed. See
[WASM capability boundary](../docs/wasm-capability-boundary.md) and current
`BrowserConversionClient`, `BrowserPiper`, `EmbeddedConverter` and
`BrowserJobStore` sources. Wiring and generated files alone do not prove browser
synthesis, cancellation, persistence or export acceptance.

## Optional HTTP compatibility

`VITE_API_BASE` and the retained HTTP client concern an explicitly selected
compatibility/server mode. For such work, inspect
`crates/converter-server/src/main.rs` and the actual frontend call sites for
current routes/payloads. The optional Rust development server/container is a
separate deployment surface; Python/FastAPI is legacy material. Building the UI
does not authorize publication or server changes.
