# ADR: Local conversion and verified source structure

Status: Accepted
Date: 2026-10-02

## Context

The product must convert books locally on every supported client, including
the CLI and Flutter/Android, without making a backend a runtime dependency.
EPUB and PDF sources need consistent chapter boundaries. A silently inferred
chapter tree can produce structurally incorrect audiobooks, especially for
scanned PDFs and documents with invalid anchors or incomplete indexes.

## Decision

Use the shared Rust converter core as the contract boundary for local
conversion. Client adapters may differ in UI and temporary engine
implementation, but must expose the same observable structure, progress,
resume, cancellation, chapter-audio, and manifest semantics.

Use the source table of contents as the preferred chapter source. Verify every
TOC item against readable content, preserve title and order, report invalid
pages/anchors, and report relevant content that is not mapped. When automatic
TOC extraction fails, derive a structure from the source EPUB/PDF/HTML data as
the explicit fallback before weaker heuristics. Show the resulting tree for
review and require confirmation when verification emits warnings.

Use Edge TTS first when online use is enabled, then a compatible local model
that is already installed and validated. Never download a model implicitly.
If OCR is unavailable or produces an untrusted section, preserve partial OCR,
stop that section, and require review before synthesis.

## Consequences

- CLI, Android, iOS, macOS, Linux, and Windows share one structure contract.
- MP3s are produced per chapter with a persistent manifest and incremental
  playback; export archives remain optional.
- PDF OCR, TOC recovery, and structure verification become explicit capability
  gates rather than silent parser behavior.
- Existing Python/backend paths may remain during migration, but must converge
  on the Rust contract and cannot define Android's runtime dependency.

## Rejected alternatives

- Treating all PDFs as one chapter or always splitting by page.
- Silently falling back to heuristics when the TOC cannot be mapped.
- Requiring a backend for Android local conversion.
- Embedding or automatically downloading local TTS models.