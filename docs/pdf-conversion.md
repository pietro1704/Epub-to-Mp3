# Native PDF narration and conversion

PDF reading uses PDFKit. Narration and MP3 conversion use the shared Rust
`converter-core` pipeline through the existing embedded C ABI, the same worker
and provider policy as EPUB. Python is not an Apple sidecar.

## Source contract

- `EmbeddedConversionSession::open` and `ConversionWorker` share format dispatch.
  A case-insensitive `.pdf` extension selects `pdf-extract 0.12.1`; EPUB retains
  its existing seekable metadata parser without buffering the full archive.
  `pdf-extract` and its `lopdf 0.42` backend are MIT licensed.
- Metadata includes title, author and catalog language when present. Title falls
  back to the file stem. Extraction does not modify the source document.
- Distinct local outline destination pages define chapter boundaries. Bookmarks
  sharing a page share an audio chapter; intrapage destination coordinates are
  not used to split its extracted text. Nested outline
  items, named destinations and physical page order are retained. Content before
  the first outline remains a front-matter chapter and is reported as content
  outside the source TOC. Non-monotonic outline page order is rejected explicitly.
- Without an outline, physical pages are the explicit source fallback. The
  existing structure contract reports a missing TOC and requires confirmation;
  this is not an inferred verified chapter tree.
- PageLabels number trees preserve decimal, Roman, alphabetic and prefixed labels.
  Physical `page-N` source anchors remain independent of displayed labels.
- Blank fallback pages retain metadata positions. Whole-book conversion omits
  empty audio without renumbering subsequent source indices. Selecting only empty
  content fails with the existing no-readable-text conversion error.
- Metadata and conversion text use the same source parser. Existing content-hash,
  provider/voice identity, cancellation and output-publication contracts apply.

## Explicit failure and resource boundaries

Malformed files, failed page extraction, invalid/cyclic local outline references
and invalid page-label trees fail explicitly. A later page failure must not
publish a silently truncated book. Password-protected PDFs require prior unlocking;
PDFs with an empty opening password can be read.

Image-only documents require OCR; no model or OCR engine is installed implicitly.
A page with no selectable text that invokes image/form drawing also requires OCR
review, including in a mixed document; it must not silently disappear from narration.
Dependency parser panics are contained before returning across the embedded C ABI.
This parser cannot recover missing OCR text or repair invalid source indexes.

The parser limits source bytes to 256 MiB, page count to 20,000, extracted text to
32 MiB and outline depth to 32. Tree traversal and page-label expansion are bounded.
File-backed PDF input is size-checked before allocation and read with a byte
limit, including if the source grows during reading. These checks do not promise
a bound on a third-party parser's peak memory or the initial synchronous PDF
object loading duration. Cancellation is checked before
extraction and between pages.

## macOS cover cache

PDFKit renders covers separately from Rust narration. Imported PDF cover payloads
record their rendering revision. A legacy row without the current revision is
refreshed on its next asynchronous book open, using the existing serial I/O worker;
startup does not scan PDF files. The visible Mac detail image follows the updated
library payload.

Only the derived cover and its revision are replaced. Source bytes, book identity,
reading position, tags and audio records remain intact. Cancellation, a replaced
bookmark or a concurrent cover edit prevents publishing an obsolete refresh.
Rendering failure retains the old cover and leaves the row eligible for a later
retry. Successfully persisted current revisions are not rendered again on open.

## Regression verification

`crates/converter-core/tests/pdf_ingestion.rs` uses standards-shaped PDF bytes
constructed independently of the extraction dependency. `pdf_conversion.rs`
exercises real WAV-to-MP3 encoding, selected sections, blank-page source ordinals,
source replacement/cache invalidation and cancellation with a deterministic speech
adapter. `book_input_streaming.rs` protects seekable EPUB metadata reads,
pre-allocation PDF size rejection and legacy worker error identity. FFI regressions
cover metadata/error recovery and real platform callbacks.

`PdfEmbeddedConversionTests` verifies a PDFKit-generated Unicode PDF through the
bundled Rust artifact, same-path replacement and meaningful corrupt-PDF errors.
Its opt-in `EPUB_PDF_GUI_ACCEPTANCE=1` case drives the actual macOS conversion
button with isolated library/defaults, checks the resulting MP3 and plays fixture
audio in the visible window. The Faber native inference suite also exercises PDF
with the original checksum-verified model, including streamed audio, completed
chapters and playback. Native reader PDF viewport tests remain separate.

Executed results, artifact identity and visible/audible acceptance must be reported
for the actual source revision. Source inspection and a green Rust suite alone do
not establish native-app acceptance. Simulator quarantine remains in force.
