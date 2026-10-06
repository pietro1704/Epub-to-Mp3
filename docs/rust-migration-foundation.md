# Rust migration foundation

## Objective

Move conversion behavior behind one Rust core reused by the CLI, the Linux GUI, the Android bridge, and the optional HTTP adapter.

## Scope of this slice

- `crates/epub2mp3-core`: format, engine, chapter, structure, job, and conversion-option contracts.
- `crates/epub2mp3-cli`: thin command-line adapter that consumes the core contracts.
- `Cargo.toml`: workspace boundary and shared lint policy.
- `mise.toml`: reproducible Rust check, test, and CLI tasks.

The existing Python path remains untouched by this slice and is not extended.

## Design constraints

- Keep domain rules in the core; adapters only translate inputs and outputs.
- Prefer one source of truth for audio extensions, engine names, and output filenames.
- Keep interfaces small so HTTP, GUI, and Android adapters can reuse the same types.
- Add dependencies only when a real implementation requires them.

## Verification

```text
mise run rust:check
mise run rust:test
mise run rust:cli -- --help
mise run rust:cli -- --format m4a book.epub
```

The current CLI validates and reports the request; EPUB parsing and synthesis are deliberately the next vertical slices.

## Rollback

Remove the new `Cargo.toml`, `crates/`, this document, and the Rust tasks from `mise.toml`. No legacy runtime files are changed by this foundation.

## Known limitations

- EPUB/PDF parsing is not implemented yet.
- TTS adapters and FFmpeg encoding are not implemented yet.
- No Flutter or Android integration is wired yet.
- The CLI currently accepts one input path.
