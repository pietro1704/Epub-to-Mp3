# Runtime navigation

Read only the branch relevant to the task. Discover exact entry points with rg
and inspect current manifests/task definitions before choosing commands.
This map describes ownership; it is not evidence that a migration or test passed.

## Shared conversion

| Surface | Start here | Responsibility |
| --- | --- | --- |
| Rust core | crates/converter-core/src/lib.rs and embedded.rs | Embedded conversion orchestration |
| Parsing/text | crates/converter-core/src/epub.rs, toc.rs, structure.rs, text.rs | Book structure and synthesis payload |
| Engines/models | crates/converter-core/src/engine.rs, tts_runtime.rs, model_catalog.rs | Provider/model configuration |
| Jobs/artifacts | crates/converter-core/src/jobs.rs, cache.rs, audio.rs, paths.rs | Progress, persistence, cache, output |
| C ABI | crates/converter-ffi/src/lib.rs | Embedded client boundary |
| Product CLI | crates/converter-cli/src/ | Direct Rust entry point |
| Web adapter | crates/converter-wasm/src/ and web/src/ | Rust/WASM integration |
| Flutter | flutter_app/ | Platform bindings to Rust |

Apple clients share the embedded core/FFI pipeline. Configure online/offline
behavior through providers/models. New shared behavior belongs in Rust and is
exposed through each relevant adapter; Python server orchestration is transitional
compatibility code, not the product architecture.

## Apple app

Start in ios/EpubToMp3/EpubToMp3/Features/:

- Conversion/Services/RustConversionCoordinator.swift: local conversion entry.
- Library/Services/LibraryStore.swift: imported book identity and persistence.
- Playback/Services/AudioPlayer.swift: queue, streaming, and playback handoff.

Locate ConverterFFIAdapter with rg before changing the Swift/C ABI seam.
Consult ios/EpubToMp3/docs/converter-ffi-ios.md for embedding details.
For reader layout/interaction, read ios/EpubToMp3/AGENTS.md, CONTEXT.md,
relevant docs/adr/, and docs/agents/reader-specialists.md.

Native tests live in EpubToMp3Tests and EpubToMp3UITests; Rust tests live in
their crate. Tooling host tests prove orchestration only. Review evidence using
[CODING_STANDARDS.md](../../CODING_STANDARDS.md).

## Device benchmarks and tooling

Read [docs/device-benchmark.md](../device-benchmark.md) for the benchmark
workflow. Run it with these tasks defined in mise.toml:

```sh
mise run ios:device:benchmark -- --device ID --case '/path/book.epub' 8 9
mise run ios:device:status
```

The range is zero-based and inclusive. The status task reads persisted execution
state and checks the recorded local process identity once; resume from that
state/report. Command availability does not prove a device run passed.

mise.toml owns project tasks. scripts/device-workflow.sh bootstraps the native
tools/DeviceWorkflow CLI; it shares the heavy-job lease with existing guards.
Python/Ruff checks remain in CI; local Apple verification uses native tools.
For legacy Python CLI/server maintenance only, read
[legacy-agent-reference.md](../legacy-agent-reference.md).
