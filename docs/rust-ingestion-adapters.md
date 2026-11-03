# Rust ingestion adapters

Boundary notes reconciled on 2026-11-03. These notes distinguish the shared core's
implemented text-layer PDF parser from deferred MOBI-family support. Client
capability is explicit.

## PDF

`PdfTextIngestion` in `crates/converter-core/src/ingestion/pdf_text.rs` uses
`pdf-extract 0.12.1`. Shared metadata/conversion dispatch lives in `book_input.rs`.
The [native PDF contract](pdf-conversion.md) defines source fidelity, outline
grouping, page-label fallback, resource limits, cancellation and explicit failures.
Outlines can group pages into chapters; one chapter per page is the fallback,
not the general chapter contract. OCR is not installed or applied implicitly.

The Rust CLI deliberately rejects both PDF conversion and structure inspection;
core support does not imply every adapter exposes the format. Apple PDF reading
uses PDFKit, independently of the Rust narration parser.

Legacy Python `pypdf` extraction and its separate Vision/OCR integration remain
compatibility references. They do not define the implemented native PDF parser
or authorize adding an OCR dependency.

## MOBI / AZW / AZW3

Legacy Python server/CLI behavior calls KindleUnpack through the `mobi` package,
then parses extracted EPUB or HTML. DRM is checked before extraction by the
caller. The Rust workspace currently has no selected KindleUnpack-compatible
crate, so the default adapter returns an explicit unsupported-format error for
all three extensions rather than treating them as EPUB or inventing a parser.

The public Rust traits and typed errors live in
`crates/converter-core/src/ingestion.rs`. A concrete MOBI-family parser and its
dependency selection remain deferred; this does not describe the active PDF path.
