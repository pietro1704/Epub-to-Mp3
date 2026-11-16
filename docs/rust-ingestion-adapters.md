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

The Rust CLI supports text-layer PDF conversion and structure inspection through
the shared parser. Apple PDF reading uses PDFKit, independently of the Rust
narration parser.

The removed legacy Python `pypdf` extraction and Vision/OCR integration do not
define the native PDF parser or authorize adding an OCR dependency.

## MOBI / AZW / AZW3

The removed legacy Python server/CLI called KindleUnpack through the `mobi`
package, then parsed extracted EPUB or HTML, checking DRM before extraction.
The Rust workspace currently has no selected KindleUnpack-compatible crate. The
Rust CLI rejects these extensions before opening or converting them.

PDF ingestion errors live in `crates/converter-core/src/ingestion.rs`. The unused
placeholder adapter traits have been removed. A concrete MOBI-family parser and
its dependency selection remain deferred; this does not describe the active PDF path.
