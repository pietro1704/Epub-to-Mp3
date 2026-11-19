# Rails web client

Server-rendered web client for EpubToMp3, built beside the React client in
`web/` until it reaches full parity (see
`docs/adr/2026-11-16-rails-web-with-browser-conversion.md`). Rails renders the
interface, negotiates locale and theme, and serves static files. Conversion,
storage and playback stay in the browser: the page loads the Rust/WASM runtime
and never uploads a book. Nothing here is deployed yet; the public Space still
ships `web/`.

The current book-selection slice accepts EPUB files up to 100 MB each through
the picker, folder input, drop area or `/sample.epub`. `runtime/workspace_store`
owns one in-memory queue and calls Rust's `inspect_epub`; no compatibility API
receives book bytes. Reordering and removal use independent entry identities,
including when the same file is selected twice. Turbo preference changes keep
the queue and File objects; a full page reload intentionally clears them.
"Convert now" waits for pending inspections and starts the selected chapters.
The progress tab streams produced segments while Rust continues conversion.

Slice 3 adds an inline/modal reader with chapters, search and persisted
preferences. Its [additive runtime contract](docs/reader-runtime-contract.md)
keeps sanitisation, pagination and text/highlight ranges in Rust. The browser
does not fall back to a JavaScript parser when those exports are unavailable.
Fixture-mode tests exercise the UI and state seam only. Build the generated
runtime and run the same suite with `CONVERTER_RUNTIME=built` to exercise the
Rust EPUB inspector, sanitiser, pagination and UTF-16 mappings in the browser.

## Narration and local models

The form reads compatible voices from the Rust catalog. Faber medium is the
default primary voice. The installed system fallback supports listening.
Per-conversion selections are captured separately from the saved preference.
Choose **Install selected model** to download its immutable catalog artifacts
into the browser's origin-private file system. The installer verifies the size
and SHA-256 of the complete pair before publishing the files in `piper/`.
If browser storage is blocked in an embedded Space, open the direct origin in
its own tab and allow site storage. [Direct Space](https://pi1704-epub-to-mp3.hf.space)

## Layout

| Path | Role |
| --- | --- |
| `app/views`, `config/locales` | The single document at `/` in `pt-BR` and `en`. Locale keys keep the names of `web/src/i18n`. |
| `app/javascript/controllers` | Stimulus controllers: presentation and user intent only. |
| `app/javascript/runtime` | First-party ES modules that talk to the generated runtime. |
| `config/importmap.rb` | Page modules, digested by Propshaft. No bundler, no transpiler. |
| `lib/converter_runtime` | Publishes and serves the generated runtime tree. |
| `browser_runtime/` | Pins the browser TTS libraries copied into the tree; `workers/` holds the Piper module worker published as `workers/` of the tree (ONNX Runtime Web and the phonemizer load as native ES modules, ADR R-02). |
| `bin/build-runtime*`, `bin/assemble-runtime` | Runtime tree build. |
| `Dockerfile`, `bin/image-regression` | Production image (repository root as context) and its checks. |

## Generated runtime tree

The conversion runtime is generated and never committed (decision D34). It is
published un-digested under `public/runtime/<id>/`, where `<id>` is the SHA-256
of the tree, and described by `config/runtime_manifest.json`; both are
gitignored. Files keep their names because the wasm-bindgen glue, Emscripten
and ONNX Runtime Web locate their siblings by relative URL. The page reads the
base path from `<meta name="converter-runtime-base">`.

```sh
# From the repository root. Compiles Rust under the native build lease.
mise run rails:web:runtime-build
```

`bin/assemble-runtime --wasm DIR [--tts DIR] [--workers DIR]` publishes files
that were already built elsewhere; it never compiles.

## Tests

```sh
mise exec -- bundle install
mise exec -- bin/rails db:prepare
mise exec -- bin/rails test:all                 # integration, library and system tests
mise exec -- node --test --test-concurrency=2 browser_runtime/
```

- Without a built runtime the tests publish a hand-written fixture module
  (`test/fixtures/converter_runtime`) so they need no Rust toolchain.
  Its inspection stub recognises only the checked-in sample bytes and returns
  fixed metadata; this mode tests the queue/UI, not the Rust EPUB parser.
  `CONVERTER_RUNTIME=built` runs the same tests against the tree produced by
  `rails:web:runtime-build`; continuous integration does that. For this mode,
  first run `mise exec -- npm ci --ignore-scripts` in `web/`. The IndexedDB
  compatibility test builds the React reference from that checkout and opens
  both clients on the same Chromium origin. Only synthesis I/O is replaced.
- System tests drive a headless Chromium through Cuprite. Set `BROWSER_PATH`
  when Chrome or Chromium is not at a standard location.
- The separate post-merge Faber job runs `REAL_BROWSER_MODEL=1 CONVERTER_RUNTIME=built
  mise exec -- bin/rails test test/system/real_browser_model_test.rb` from
  this directory. It exercises the explicit install in an isolated browser,
  verifies both OPFS checksums, decodes each MP3 and writes
  `tmp/real-browser-model.json`.
- Tests run with at most two workers.

## Configuration

| Variable | Purpose |
| --- | --- |
| `SECRET_KEY_BASE` | Required in production; the preferences form uses the cookie session for CSRF protection. |
| `RUST_CONVERTER_URL` | Mounts the server-side compatibility API (`/books…`, `/api/metadata`) that delegates to `converter-server`. Unset, those routes answer 404. The interface never calls them. |
| `APP_VERSION` | Overrides the version shown in the footer (`VERSION`). |
| `HTTP_PORT`, `TARGET_PORT` | Thruster's public port (7860 in the image) and Puma's loopback port. |

`GET /api/health` and `GET /health` answer locally with
`{"status":"healthy","contract_version":"1","backend":"rails"}`.

## Response policy

- `/assets/*` and `/runtime/<id>/*` are `public, max-age=31536000, immutable`;
  HTML and un-versioned public files are `no-cache`.
- `.wasm` is served as `application/wasm`, `.js` and `.mjs` as `text/javascript`.
- No COOP/COEP headers: ONNX Runtime stays single-threaded.
- The enforced Content-Security-Policy admits model fetches from
  `huggingface.co` and the observed weight redirect `us.aws.cdn.hf.co`.
  `frame-ancestors 'self' https://huggingface.co` allows the Space page
  to embed the application.
