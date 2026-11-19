# CLI and Web

The product CLI is Rust (`crates/converter-cli/`). The root `convert` task invokes
`scripts/package_rust_cli.rb --run --`, which builds/packages native runtime and
phonemizer assets before running the CLI. It is not a read-only help shortcut;
inspect prerequisites and guarded build policy before using it.

For an authorized conversion with existing prerequisites:

```sh
mise run convert -- book.epub
mise run convert -- book.epub --chapter position:2
mise run convert -- book.epub --show-structure
```

These examples follow current task/parser source; they are not executed acceptance
evidence. The CLI converts and inspects (`--show-structure`) EPUB and text-layer
PDF through the shared source dispatch; a PDF without extractable text fails
before any job starts. See the [PDF contract](../../pdf-conversion.md). Use repeated `--chapter` flags for multiple literal chapter
IDs; `position:N` explicitly selects a zero-based position. Inspect current parser/help
for batch, output, verification and preference options rather than carrying over
Python flags or assuming all product-target formats work.

Piper `pt_BR-faber-medium` is primary; explicit per-job selections override saved
choices. Online Edge fallback requires explicit consent. Model installation is a
separate explicit action. Cache clearing is destructive and is not part of a
conversion quickstart.

The normal web client is the Rails client with embedded Rust/WASM and browser
Piper; conversion runs in the browser. Follow
[the Rails web README](../../../ruby_app/rails_gateway/README.md) for the
generated runtime tree (`mise run rails:web:runtime-build`) and tests
(`mise run rails:web:test`). The former React/Vite client in `web/` was removed
in the Rails cutover.
Browser native speech is listening-only; exporting MP3 requires installed Piper.
EPUB inspection support does not prove PDF or other native-format capability.

`mise run dev` was written to start the optional Rust server plus the former Vite frontend (inspect the task and `scripts/dev.sh` first, since the React client was removed), can compile/install
missing dependencies and manages development processes. Use it only for an
explicit server journey after inspecting `scripts/dev.sh` and task scope.
`converter-server` and the retained HTTP client are compatibility adapters; actual
routes/payloads belong to current Rust server and selected client sources.
The legacy Python/FastAPI server and `hf_app.py` were removed.
