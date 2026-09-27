# Rust differential conversion results

Migration-only evidence template for Phase 6 Task 6.1. The harness is
`scripts/differential_conversion.py`; it compares canonical JSON emitted by the
Python and Rust commands and normalizes only volatile metadata.

## Run metadata

- Date:
- Commit:
- Python command:
- Rust command:
- Corpus: `tests/fixtures/rust_parity/v1/`
- Normalization policy: structural key ordering; UUIDs, generated IDs, absolute
  paths, generated-ID URLs, timestamps, and elapsed-time fields become typed
  placeholders. User text, arrays, counts, hashes, errors, nulls, and field
  presence remain significant.

## Results

| Fixture | Python digest | Rust digest | Status | Notes |
| --- | --- | --- | --- | --- |
| `parsed.json` | | | | |
| `normalized_text.json` | | | | |
| `chunks.json` | | | | |
| `cache_keys.json` | | | | |
| `job.json` | | | | |
| `fulltext.json` | | | | |
| `stream_manifest.json` | | | | |
| `sse.ndjson` | | | | |

## Interpretation

- A `match` means the normalized JSON trees have identical SHA-256 digests.
- A `MISMATCH` requires preserving both raw outputs and documenting the first
  structural difference before changing either implementation.
- This harness may depend on Python temporarily for migration comparison and is
  removable once Rust is the sole conversion implementation.
