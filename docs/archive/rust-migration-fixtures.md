# Rust migration golden fixtures

The corpus under `tests/fixtures/rust_parity/v1/` is the versioned, deterministic
intermediate contract for the Python-to-Rust migration. `manifest.json` lists
fixture names, source inputs, and SHA-256 digests; each sibling JSON file is a
canonical snapshot produced by `test_rust_parity_fixtures.py`.

## Files and schema

- `parsed.json`: book metadata, TOC (including nested children), and chapter
  fields needed by the parser (`index`, `name`, `sourcePath`, `text`, `level`,
  formatting, speech text, footnotes, and stable identity).
- `normalized_text.json`: raw and speech text after the public text sanitation
  and formatting boundaries, preserving Unicode, line breaks, nulls, and empty
  values.
- `chunks.json`: regular and streaming `prepare_chunks` results, including
  resolved voice and ordered chunk strings.
- `cache_keys.json`: known deterministic digest inputs and resulting keys.
- `job.json`: persisted finished and failed job shapes, with volatile metadata
  normalized.
- `fulltext.json`: canonical full-text response shape, including cache hit/miss
  states.
- `stream_manifest.json`: public stream manifest plus retired-publication
  behavior.
- `sse.ndjson`: ordered SSE event records, one JSON object per line.

## Normalization

Snapshots are serialized with sorted object keys, UTF-8, and a trailing newline.
Arrays retain their production order; counts, hashes, error strings, nullability,
and field presence are never discarded. Only volatile values are replaced: UUIDs,
absolute paths, URLs containing generated identifiers, timestamps, elapsed-time
fields, and attempt/publication/request IDs become typed placeholders such as
`<uuid>`, `<path>`, `<url>`, `<timestamp>`, `<elapsed-ns>`, or `<id>`.

The normalizer is deliberately structural: it does not replace arbitrary strings
or change user text. A fixture update must be intentional: run the focused test,
review the generated diff, and commit the corpus and test together.
