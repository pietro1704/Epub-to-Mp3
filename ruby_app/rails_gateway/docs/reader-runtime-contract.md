# Browser reader runtime contract (version 1)

This is the additive boundary for ADR 2026-11-16, slice 3. The Rails adapter
requires these exports; the handwritten test runtime is not evidence that the
real Rust/WASM implementation exists or passes acceptance.

## Exports

`reader_inspect_epub_json_v1(bytes: Uint8Array): string` returns a JSON book:

```json
{
  "bookTitle": "Title",
  "bookAuthor": "Author",
  "language": "pt-BR",
  "chapters": [{
    "index": "1.1",
    "name": "Chapter name",
    "sourcePath": "OEBPS/chapter.xhtml",
    "level": 2,
    "text": "Fallback text",
    "html": "<h2 id=\"start\">Chapter name</h2><p>Text.</p>",
    "css": "p { text-align: justify; }"
  }]
}
```

`index` is the literal core chapter identity, including hierarchical strings;
the browser never renumbers or numerically parses it. Rust guarantees nonempty,
unique string indices within the document, valid chapter field types and
bounded input/resource/output sizes. Malformed or ambiguous payloads fail at
that boundary; the JS adapter only checks the response envelope and contract
version, not the EPUB structure or resource policy. `sourcePath` and `level`
survive inspection. The existing `inspect_epub` export remains unchanged.
Reader-only spine items without a TOC identity (for example an illustration
that conversion omits) use reserved identity `0.<one-based spine position>`.
They never advance the legacy orphan counter or renumber convertible chapters;
TOC-derived identities still take precedence. Playback indices therefore keep
their existing meaning when the reader retains extra visual content.

`reader_chapter_json_v1(requestJson: string): string` accepts:

```json
{
  "version": 1,
  "html": "<p>Olá 😀 café.</p>",
  "text": "Olá 😀 café.",
  "css": "",
  "preferences": { "fontScale": 1.05, "lineHeight": 1.75, "widthRem": 48 },
  "searchText": "café",
  "audioText": "Olá 😀"
}
```

The UI also sends its theme/font/follow preferences; only typography controls
affect pagination. Optional `html`/`css` may be absent. Plain text supplies the
escaped fallback, never an unsanitised HTML alternative. A response has:

```json
{
  "version": 1,
  "offsetUnit": "utf16",
  "text": "Olá 😀 café.",
  "css": "",
  "pages": [{ "html": "<p>Sanitised markup with generated marks</p>", "start": 0, "end": 12 }],
  "searchMatches": [{ "start": 7, "end": 11, "pageIndex": 0 }],
  "audioMatch": { "start": 0, "end": 6, "pageIndex": 0 },
  "anchors": [{ "id": "start", "pageIndex": 0 }]
}
```

The markup above is schematic. Every range is **half-open UTF-16 code units**
on the canonical `text` returned in that same response. It is not a byte
offset, Rust `char` count, HTML-string offset or an offset into the original
EPUB fallback text. The canonical text follows the sanitised text-node order,
with a single structural `\n` between visible text separated by block boundaries
or `<br>`. Inline formatting does not introduce a separator. Leading/trailing
structural separators and source indentation between blocks are omitted;
literal whitespace inside readable text, including `<pre>`, remains unchanged.
These separators advance the same Rust projection used by pagination and
highlight serialization; they do not add visible whitespace or HTML children.
The canonical text therefore deliberately differs from DOM `textContent`.
For example, `<p>😀ab</p><p>cd<br>ef</p>` projects to `😀ab\ncd\nef`;
`cd` starts at UTF-16 offset 5 and searching `abcd` finds nothing.
Entity decoding and dropped active/media content also affect that axis. Astral
characters occupy two code units; combining marks retain their source order.
Page and match indices are zero-based. The UI consumes mappings; it does not
derive them from DOM text or repeat search/pagination in JavaScript.

Search is literal, uses Unicode scalar lowercase mappings and is non-overlapping.
It does not normalize combining marks or remove accents. A match cannot begin
or end inside the lowercase expansion of one source scalar. The empty query has
no matches. Audio matches the first exact occurrence and returns `null` when
absent. Rust emits `data-reader-search="<match index>"` and
`data-reader-audio="true"` markers, including when ranges span formatting
nodes; markup cannot counterfeit these markers. Empty content returns an
empty page list; malformed EPUB/input and resource-limit failures throw an
error instead of pretending that an empty reader succeeded.

## Fidelity and safety

Rust owns sanitisation, layout grouping, search, ranges and highlights. The
UI inserts only returned `pages[].html` and `css` into a shadow root. It creates
the CSS element with the initial HTTP document's CSP nonce (retained across
Turbo body changes) and assigns CSS using `textContent`.
The existing CSP does not admit arbitrary inline `style` attributes; safe
source declarations should be emitted as classes plus sanitised stylesheet
rules. HTML/body language, direction and classes survive in generated wrappers;
CSS type selectors `html`/`body` target their reserved `reader-root-*` classes.
Source elements cannot claim those reserved classes. Repeated page wrappers
keep presentation attributes but retain each anchor ID only on its first page.
Do not relax CSP or add a JavaScript sanitiser to compensate.

Preserve readable text, headings, paragraph/list/table structure, emphasis,
language and direction. Retain validated local raster images as bounded data
URLs and accessible image alternatives. No markup, stylesheet, font or image
may trigger an implicit remote request. Active elements, event handlers,
unsafe URL schemes, CSS imports/URLs/expressions, SVG active content and
resource/decompression bombs are hostile inputs, not presentation features.

Resolve internal source paths/fragments in Rust. A resolved link carries
`data-reader-chapter="<literal index>"` and `data-reader-fragment="<id>"`.
The browser requests that chapter and navigates through returned
`anchors: [{id, pageIndex}]`; it never resolves book-relative paths itself.
Explicit external HTTP/HTTPS/mailto links may remain clickable only when
validated, with `target="_blank"` and `rel="noopener noreferrer"`.

The React reference groups whole blocks with an approximate character budget
of `clamp(round(2200 * widthRem/48 * 1.05/fontScale * 1.75/lineHeight),900,4200)`.
It does not split long blocks. Any oversized block remains fully scrollable;
pagination must never discard text or clip a glyph to force a fixed height.

## Bounded inputs and styling subset

The reader uses HTML5 tree repair and an owned allowlist before serialization.
The conversion inspector keeps its existing behavior; only the additive reader
inspector retains image-only spine items. Metadata, hierarchical indices and
chapter labels still come from the shared EPUB parser. Duplicate chapter
identities fail. Missing optional images become their readable `alt` text;
missing stylesheets lose only styling. Resource-limit errors do not silently
turn into partial success.

| Resource | Limit |
| --- | --- |
| Compressed EPUB / archive entries / chapters | 100 MiB / 4,096 / 2,048 |
| Decompressed resource / total reads | 8 MiB / 64 MiB across two 32 MiB budgets |
| Chapter markup or fallback text | 2 MiB each |
| Request JSON / serialized response | 8 MiB / 32 MiB |
| CSS per chapter / admitted rules | 256 KiB / 2,048 |
| Markup source tokens / copied nodes / source depth | 25,000 / 50,000 / 128 |
| Raster images per chapter / resource bytes | 128 / 1 MiB each before base64 |
| Raster dimensions / pixels | 8,192 per axis / 20 million |
| Search input / audio input / matches | 4 KiB / 64 KiB / 10,000 |

Local PNG, JPEG and WebP containers must have bounded dimensions and complete
container boundaries before being embedded. Animated PNG/WebP, SVG, remote
images, fonts and unsupported media are not embedded. The browser's image
decoder still determines whether the admitted raster can render.

CSS admits simple type/class/ID selectors, descendant/child/sibling combinators,
comma groups and `*`. Declarations cover typography, alignment, decoration,
colors, borders, margins and padding. Positioning, dimensions, overflow,
visibility, display and opacity are excluded. Font size and line height have
bounded readable ranges. Escapes, at-rules, custom properties, `!important`,
URLs and functions other than `rgb`, `rgba`, `hsl`, `hsla` are discarded.
Unsupported declarations never remove document text. The exact property
allowlist is in `converter-core/src/reader/css.rs`.

## Browser state and verification

`workspace_store.readerSession` is the singleton for book/chapter/page/search
selection. A newer read/search invalidates an older asynchronous completion;
removing its book closes the reader. Switching locale/theme through Turbo
preserves the selected book and page. Inline/modal use the same DOM content.

`epub-to-mp3:reader-prefs` retains the React object shape: `fontScale`,
`lineHeight`, `widthRem`, `theme` (`paper|mist|ink`), `fontFamily`
(`serif|sans`) and `followAudio`. Invalid/blocked storage falls back to usable
defaults. Playback integration calls `readerSession.followAudio` with
`{bookId, chapterIndex, segmentText}`. Slice 4 must supply the same literal string
`chapterIndex` returned by the inspector, including hierarchical indices;
numeric conversion is not compatible with the contract. A different book cannot move this reader;
manual chapter selection pauses follow until narration changes chapter or
the user explicitly re-enables follow. The pause itself is not persisted.

`test/fixtures/reader_contract.json` supplies raw hostile source and static
golden responses for the fixture runtime. Unknown chapters deliberately fail;
the fixture has no general EPUB parser, sanitiser, paginator or matcher.
System tests inject that source document but still call the production reader
adapter and its runtime export. `CONVERTER_RUNTIME=built` must run the same
journeys against generated Rust/WASM, plus Rust's hostile/fidelity corpus,
before claiming parser/sanitiser/layout acceptance. The sample-book journey
also exercises the new inspector export without injecting a document.
