# CLI and Web

The product CLI is Rust (`crates/converter-cli/`). The root `convert` task invokes
`scripts/package_rust_cli.rb --run --`, which builds/packages native runtime and
phonemizer assets before running the CLI. It is not a read-only help shortcut;
inspect prerequisites and guarded build policy before using it.

For an authorized conversion with existing prerequisites:

```sh
mise run convert -- book.epub
mise run convert -- book.epub --chapter 3
mise run convert -- book.epub --show-structure
```

These examples follow current task/parser source; they are not executed acceptance
evidence. CLI help currently rejects PDF ingestion. Inspect current parser/help
for batch, output, verification and preference options rather than carrying over
Python flags or assuming all product-target formats work.

Piper `pt_BR-faber-medium` is primary; explicit per-job selections override saved
choices. Online Edge fallback requires explicit consent. Model installation is a
separate explicit action. Cache clearing is destructive and is not part of a
conversion quickstart.

The normal web client is embedded Rust/WASM with browser Piper. Follow
[web/README.md](../../../web/README.md) for Vite and focused lint/test/build tasks.
Browser native speech is listening-only; exporting MP3 requires installed Piper.
EPUB inspection support does not prove PDF or other native-format capability.

`mise run dev` starts the optional Rust server plus Vite, can compile/install
missing dependencies and manages development processes. Use it only for an
explicit server journey after inspecting `scripts/dev.sh` and task scope.
`converter-server` and the retained HTTP client are compatibility adapters; actual
routes/payloads belong to current Rust server and selected client sources.
Python/FastAPI recipes and `hf_app.py` are legacy, not the default launch path.
