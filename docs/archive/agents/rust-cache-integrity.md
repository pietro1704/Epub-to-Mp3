# Phase 2 Task 2.4 — cache, hashing, integrity, deduplication

The Rust core exposes cache primitives matching the migration contract:

- deterministic SHA-1 text keys and SHA-1/SHA-256 streaming file digests;
- normalized text integrity keys;
- atomic JSON replacement with full-file sync before rename;
- safe managed-cache child paths that reject absolute paths and traversal;
- duplicate tracking keyed by byte-identical audio, while requiring substantive text.

Existing Python cache entries remain readable by callers through the JSON reader; metadata validity remains based on source size and modification time. Protected-directory policy and higher-level cache layout remain owned by the integration layer.
