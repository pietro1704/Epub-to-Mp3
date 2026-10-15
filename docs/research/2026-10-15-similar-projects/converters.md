# Similar converters and audiobook export consumers

Evidence collected: 2026-10-15. Research only: no third-party software, model,
audio or service was installed, executed, synthesized, uploaded or benchmarked.
HTTP requests read public documentation, source and repository metadata only.
Local comparison: `a41b61ffc1c980e58c52f51eca246b59e979ae3c` plus the existing dirty
worktree. In particular, `worker.rs` and `jobs.rs` already have unrelated pending
changes; the observations below do not claim those changes are delivered.

## Source inventory and reproducibility

| Project | Inspected revision | Primary evidence | Reuse boundary |
| --- | --- | --- | --- |
| p0n1/epub_to_audiobook | `v0.8.7`, commit `2b021541a93e21927ed8614b5e9cde5ab7709b81`, committed 2026-02-02 | [Commit API](https://api.github.com/repos/p0n1/epub_to_audiobook/commits/v0.8.7), [README](https://github.com/p0n1/epub_to_audiobook/blob/2b021541a93e21927ed8614b5e9cde5ab7709b81/README.md), source links below | [MIT license](https://github.com/p0n1/epub_to_audiobook/blob/2b021541a93e21927ed8614b5e9cde5ab7709b81/LICENSE); this research proposes independent Rust implementations, copying no source. |
| DrewThomasson/ebook2audiobook | `0a98ac313ec43a470ee1e5feb13dd881ffb3e969`, committed 2026-10-06 | [Commit API](https://api.github.com/repos/DrewThomasson/ebook2audiobook/commits/main), [README](https://github.com/DrewThomasson/ebook2audiobook/blob/0a98ac313ec43a470ee1e5feb13dd881ffb3e969/README.md), source links below | [Apache-2.0 license](https://github.com/DrewThomasson/ebook2audiobook/blob/0a98ac313ec43a470ee1e5feb13dd881ffb3e969/LICENSE); application license is separate from any model/voice terms. |
| Audiobookshelf | `743d9152208507a1dbf7c95c94290071338f44bd`, committed 2026-10-05 | [Commit API](https://api.github.com/repos/advplyr/audiobookshelf/commits/master), [scanner source](https://github.com/advplyr/audiobookshelf/blob/743d9152208507a1dbf7c95c94290071338f44bd/server/scanner/AudioFileScanner.js), [official export-consumer documentation](https://audiobookshelf.org/docs/documentation/libraries/book-library/directory-structure/) | [GPLv3 license text](https://github.com/advplyr/audiobookshelf/blob/743d9152208507a1dbf7c95c94290071338f44bd/LICENSE). Observe public file interoperability; do not transplant scanner implementation. |
| ebook2audiobook Hugging Face Space | API HEAD `e79c654e7cc10f94dc3d6afba0fb8c18480f8a77`, last modified 2026-10-15 | [Space API](https://huggingface.co/api/spaces/drewThomasson/ebook2audiobook), [README revision actually read](https://huggingface.co/spaces/drewThomasson/ebook2audiobook/blob/5565b6be46fa56cad4394f5f6cf23bd7acb85685/README.md) | Docker Space metadata, Apache-2.0 declaration; no hosted inference was invoked. API HEAD differs from the README's last-change commit; pinned HEAD README could not be retrieved through the browser. |

The GitHub commit APIs were read directly when the browser could not fetch them.
API links identify retrieval endpoints and may move; immutable blob links identify
the inspected code. The HF Space is a deployment of the same converter, not an
independent confirmation of model quality or mobile suitability. Its metadata
shows Docker and a project version; no latency or memory conclusion follows.
[HF README](https://huggingface.co/spaces/drewThomasson/ebook2audiobook/blob/5565b6be46fa56cad4394f5f6cf23bd7acb85685/README.md)

## Prioritized ideas and actual local gaps

### C1 — Bound artifact filenames by UTF-8 bytes (implement first)

**External evidence.** p0n1's filename helper detects a filename budget, accounts
for prefix/extension, truncates on UTF-8 boundaries and adds a deterministic hash
when truncating. This is a useful pattern, not a reason to copy its Python or
normalization choices. [Pinned filename helper](https://github.com/p0n1/epub_to_audiobook/blob/2b021541a93e21927ed8614b5e9cde5ab7709b81/audiobook_generator/utils/filename_sanitizer.py#L41-L111)

**Local gap.** `worker.rs::sanitize` replaces disallowed characters and collapses
whitespace but imposes no byte limit. The worker forms chapter names from the
selection position and full sanitized title, and the ZIP name from the full book
title. Long multibyte titles can therefore exceed a filesystem component limit.
This is a source-based failure hypothesis; no production book failure was
reproduced during this research. [Local worker](../../../crates/converter-core/src/worker.rs)

**Proposed small Rust slice.** Introduce a cohesive artifact-name helper. Preserve
existing short names exactly; bound the complete component, including numbered
prefix, extension, receipt suffix and temporary-name reserve; retain valid UTF-8;
append a deterministic digest only when truncating. Use the same derivation for
conversion and recovery lookups. Do not change chapter identity or rendered
book/chapter titles. Prefer a conservative portable component budget over a new
platform-specific runtime dependency.

**Acceptance.** Native Rust unit tests for ASCII, Portuguese accents, CJK, empty
sanitized text, oversized prefix, deterministic output and two long titles with
the same prefix. An integration fixture should create the resulting file on disk,
read it back and exercise resumed artifact lookup; existing short-name output
must stay byte-identical. This slice needs no model, network, GPU or UI changes.
The occupied worker ownership must be reconciled before integration.

### C2 — Carry chapter metadata in each exported MP3

**External evidence.** p0n1 models chapter title, author, book title and track
index explicitly as ID3 fields. [Pinned AudioTags](https://github.com/p0n1/epub_to_audiobook/blob/2b021541a93e21927ed8614b5e9cde5ab7709b81/audiobook_generator/core/audio_tags.py)
Audiobookshelf reads author/book metadata and orders tracks using audio metadata
and filenames; its scanner uses per-file title tags as chapter names only under
specific completeness/uniqueness conditions. [Official mapping](https://audiobookshelf.org/docs/documentation/libraries/book-library/directory-structure/#file-metadata), [pinned scanner](https://github.com/advplyr/audiobookshelf/blob/743d9152208507a1dbf7c95c94290071338f44bd/server/scanner/AudioFileScanner.js#L463-L534)

**Local state/gap.** `OutputManifest`/`ChapterMetadata`, ordered chapter filenames,
cover export, ZIP creation and `audio::embed_cover` already exist. Inspection
found no production setter for ID3 title/artist/album/track in the core; existing
ID3 title/artist setters found by search are fixtures. The gap is portable
metadata, not a new archive or chapter model. [Local audio](../../../crates/converter-core/src/audio.rs), [worker](../../../crates/converter-core/src/worker.rs)

**Proposal.** Add these tags in Rust before final receipt hashing/publication,
preserving existing frames and decoded audio. Track numbering must describe the
exported selection while `source_index` stays canonical. Test decoded audio
identity, tag round-trip, Unicode titles, preexisting cover, missing metadata,
write failure and cancellation between finalization steps. Duplicate chapter
titles require a documented consumer fallback; do not silently rename literary
titles solely to satisfy another application's heuristic.

### C3 — Preview the exact synthesis payload without invoking a provider

**External evidence.** p0n1 exposes preview mode, chapter character counts and
optional text output. Its orchestration bypasses synthesis for preview.
[Pinned CLI](https://github.com/p0n1/epub_to_audiobook/blob/2b021541a93e21927ed8614b5e9cde5ab7709b81/main.py#L25-L69), [generator](https://github.com/p0n1/epub_to_audiobook/blob/2b021541a93e21927ed8614b5e9cde5ab7709b81/audiobook_generator/core/audiobook_generator.py#L34-L53)

**Local state/gap.** Rust CLI `--show-structure` already displays title and chapter
indices/names. EPUB parsing and shared text normalization already exist. An
incremental preview could expose selected indices, Unicode character counts and
normalization warnings from the exact worker payload. Avoid inventing a second
parser or shipping provider-dependent prices as static facts.
[CLI](../../../crates/converter-cli/src/main.rs), [text](../../../crates/converter-core/src/text.rs)

**Acceptance.** Parsed fixture → shared payload preview → same worker text/count;
empty chapter and malformed EPUB errors; a fake provider proving zero synthesis
calls; no model install or paid API prerequisite. An audio voice preview is a
separate explicit action.

### C4 — Optional pronunciation substitutions with explicit cache identity

**External evidence.** p0n1 accepts a search/replace file for pronunciation and
abbreviation changes, including regex boundaries. [Pinned CLI option](https://github.com/p0n1/epub_to_audiobook/blob/2b021541a93e21927ed8614b5e9cde5ab7709b81/main.py#L80-L86), [documented examples](https://github.com/p0n1/epub_to_audiobook/blob/2b021541a93e21927ed8614b5e9cde5ab7709b81/README.md#search--replace)

**Local state/gap.** `text.rs` has structural normalization but the inspected Rust
core has no user pronunciation rule set. Propose bounded literal substitutions
first, opt-in per job/book, preserving imported source and reader text. Include
rules and their order in synthesis/cache/receipt identity. Do not import an
unbounded arbitrary-regex file format by default.

**Acceptance.** Portuguese names/abbreviations, overlapping rules, deterministic
order, Unicode boundaries, invalid/oversized input, no-rule identity and changed
rules invalidating cached audio. This affects synthesized content and therefore
requires more policy/UX work than C1.

### C5 — Offer a local library-ready export before remote integration

**External evidence.** ebook2audiobook contains an Audiobookshelf uploader that
selects library/folder IDs and performs authenticated multipart upload. Its README
also advertises M4B and resumable sessions. [Pinned uploader](https://github.com/DrewThomasson/ebook2audiobook/blob/0a98ac313ec43a470ee1e5feb13dd881ffb3e969/lib/classes/audiobookshelf.py#L65-L126), [README](https://github.com/DrewThomasson/ebook2audiobook/blob/0a98ac313ec43a470ee1e5feb13dd881ffb3e969/README.md#help-command-output)
Audiobookshelf documents one folder per multi-file book and can read an OPF
sidecar. [Official structure](https://audiobookshelf.org/docs/documentation/libraries/book-library/directory-structure/), [official metadata documentation source](https://github.com/audiobookshelf/audiobookshelf-docs/blob/master/docs/documentation/libraries/book-library/2.book-metadata.md)

**Local state/gap.** The core already packages separate MP3s and cover into ZIP
and saves a product `manifest.json`. A product manifest is not Audiobookshelf's
`metadata.json` schema. A future explicit export profile could create one book
folder with portable tags and an OPF sidecar; never label the current JSON
interoperable without a schema/import fixture. Direct upload needs a separate
authorized service action, credential handling and an export transaction model.
M4B packaging can be a later optional postprocessing step, preserving early MP3
playback instead of delaying first playable audio.

**Existing capability to preserve.** `JobManager::recover_active`, worker
`resume`, model/request-bound completion receipts, cancellation and playback
window control already exist. ebook2audiobook's session/block recovery is useful
as comparative evidence, not justification to build a duplicate Python session
runtime. Inspect these Rust seams before proposing any recovery work.
[Jobs](../../../crates/converter-core/src/jobs.rs), [worker](../../../crates/converter-core/src/worker.rs), [control](../../../crates/converter-core/src/conversion_control.rs), [external block recovery](https://github.com/DrewThomasson/ebook2audiobook/blob/0a98ac313ec43a470ee1e5feb13dd881ffb3e969/lib/core.py#L2662-L2670)

## Decision boundary

Adopt behavior ideas independently in Rust; keep Swift native UI and the embedded
FFI runtime. No Python/Gradio sidecar, paid-provider requirement, implicit model
download, automatic Edge fallback, voice cloning, music generation or GPU-heavy
parallelism is proposed. Application licenses do not establish model-weight,
voice, dataset or ebook redistribution rights. No third-party source or assets
were copied into the product by this research.

Priorities: C1 is the smallest immediate robustness slice; C2 improves export
portability; C3 makes conversion inspectable; C4 needs content/cache policy; C5
is a future opt-in export/integration feature. These priorities are engineering
inferences from inspected source, not measured speed, voice-quality or
cross-application compatibility claims.
