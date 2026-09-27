# Rust ingestion adapters

Phase 2 Task 2.3 adds explicit adapter boundaries for PDF and MOBI-family
sources without selecting a Rust parsing dependency prematurely.

## PDF

The current Python behavior is `pypdf` text-layer extraction, one chapter per
page, metadata title/author fallback to the filename, whitespace normalization,
and an error when a non-empty PDF has no readable text. Scanned-page recovery
uses the separate Vision/OCR path and is not silently emulated here. A future
`PdfIngestionAdapter` implementation must preserve those semantics and may set
`source_format` to `pdf_scan_ocr` only when the OCR/cache contract is ported.

## MOBI / AZW / AZW3

The current server/CLI behavior calls KindleUnpack through the `mobi` package,
then parses extracted EPUB or HTML. DRM is checked before extraction by the
caller. The Rust workspace currently has no selected KindleUnpack-compatible
crate, so the default adapter returns an explicit unsupported-format error for
all three extensions rather than treating them as EPUB or inventing a parser.

The public Rust traits and typed errors live in
`crates/converter-core/src/ingestion.rs`. Dependency selection and concrete
parsers are intentionally deferred to the next migration decision.
