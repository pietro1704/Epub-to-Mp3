# IOS-19: reviewed Piper boundary and sizing proposal

Reviewed 2026-10-29 against source commit
`3396d04f7328d42fa410bb97be41854376e71161`. Research only: no production
change, compilation, synthesis, benchmark, device action or model download.

## Recommendation

Keep the current nominal first/steady budgets of 180/800 Unicode scalars as
the control. Improve sentence/paragraph boundary selection before comparing
sizes. Neither the current application cap nor eSpeak's internal byte buffer
establishes an acoustically optimal Piper input size. No production size change
is justified by this review. [1][2][6]

The preceding report attributes a 700-character sentence-ending example and a
below-800 recommendation to Akita's Appendix K, “A dublagem, bloco por bloco”,
`EPUB/text/ch038.xhtml`, for ElevenLabs dubbing. That local EPUB passage was
**not reopened in this review**. Its provenance remains the preceding report's
recorded direct reading, not a new independent book verification. Even if that
account is accepted, it is evidence about that dubbing workflow rather than a
Piper benchmark or a current universal ElevenLabs limit. [11]

## Source findings

The six central source files listed in the original review (typed worker,
segmenter, pronunciation, EPUB text projection, whole-chapter cache and IOS-06
seek contract) are unchanged between its `f3e46180719f9f304ed242d54784e077bd390f5c`
baseline and this review's commit; a read-only `git diff --exit-code` succeeded.
Their current behavior is:

| Seam | Verified behavior and consequence |
| --- | --- |
| Typed worker | Captures the minimum advertised primary/secondary adapter capacity, capped at 800; rejects zero capacity. Source segmentation uses first `min(180, limit)`, then `limit`. Pronunciation expansion is bounded and spoken payloads are split again against the selected adapter's capacity. A fallback system voice uses nominal 60/240 source budgets to retain useful short recovery points. [1] |
| Shared text segmenter | `char_indices().nth(limit)` sets a Unicode-scalar ceiling before protected-range adjustment. A single backward search considers whitespace and `.?!` equally, so a later space can defeat a complete sentence boundary. Its half-window filter uses UTF-8 byte offsets. It trims boundary whitespace and returns strings, not explicit source ranges; source-range/coverage adoption must account for consumed whitespace rather than reconstruct offsets by concatenating trimmed payloads. [2] |
| Pronunciation | Literal matches carry byte ranges and remain whole across source cuts by extending a crossing boundary. Thus 180/800 are soft source targets, not unconditional source maxima. Validated terms are at most 200 scalars; replacements at most 400. The later unprotected speech split still bounds actual adapter calls. [1][3] |
| EPUB normalization | Block tags contribute spaces; final `split_whitespace().join(" ")` removes paragraph structure. Searching normalized chapter text for blank lines cannot restore paragraph boundaries. [4] |
| Piper/eSpeak | The pinned piper-rs wrapper joins phonemized sentences and performs one inference per `create` call. Native Piper advertises after-call cancellation and no within-call streaming; progressive publication happens between worker calls. eSpeak's `N_TR_SOURCE 800` is a clause buffer measured in UTF-8 **bytes**, and its reader/wrapper continue through the input. [5][6] |
| Caches/publication | Whole-chapter identity includes `text-v1`, request selections, runtime descriptors and relevant artifact/pronunciation identity. Inner cache identity includes book, language, source-plus-spoken payload and resolved synthesis identity. Generation/window checks guard synthesis, caching and chunk delivery. Changed boundary semantics need versioned identity before reuse can represent the new evaluation. [1][7] |
| IOS-06 seek | Requested timeline seconds resolve from contiguous measured audio durations, including the in-chunk offset. Without a trusted timing map, an ungenerated target requires generating/measuring its prefix. Text ratios or estimated seconds-per-chunk cannot provide exact random-access generation. [8] |

The separate remote adaptive constants 4096/2048/6144 and initial concurrency 2
are not the typed native worker's 180/800 source profile; preserve that distinction
rather than presenting a historical remote policy as actual current Apple call
sizes. Likewise `ListeningPlan`'s 480 multiplier predicts prefix generation time;
it is not a chunk-size recommendation. [1][9]

## Proposed policy and compatibility

**First isolate boundary selection.** Keep the captured 180/800 control budgets
and adapter hard capacity. Return ordered source ranges plus speech payloads,
with explicit conversion between UTF-8 bytes and the canonical Unicode-scalar
source axis. Prefer a complete paragraph near the target, then a complete
sentence, then a clause/word boundary. Retain a usable earlier complete boundary
when the latter half contains none. Keep the first payload small; a long first
paragraph must not force full-paragraph startup. [1][2][4]

Sentence recognition must handle Portuguese abbreviations and initials, decimal
numbers, ellipses, closing quotes/brackets and dialogue dashes. Unicode UAX #29
is a segmentation/tailoring reference, not proof that this application already
implements those rules. Respect extended grapheme boundaries for final cuts;
reject an unrepresentable atom explicitly instead of looping or exceeding the
adapter capacity. [10]

Move candidate cuts before protected pronunciation matches where possible.
Keep a protected term whole only if the actual call capacity allows it, then
validate expanded spoken payloads again. Do not insert punctuation or silence
to disguise an artificial cut, change reader text, or lose/duplicate source
coverage. The final source range includes consumed canonical whitespace even
when the synthesis payload omits boundary whitespace. [1][2][3]

**Paragraph metadata is a parser change.** Preserve paragraph-end offsets as
validated sidecar metadata on the existing normalized scalar coordinate axis.
Keep canonical text, TOC hierarchy, labels, order and existing `text_offset`
meaning unchanged. Missing metadata uses sentence/word behavior; invalid or
out-of-range metadata must fail closed or be explicitly ignored under a tested
compatibility rule. Do not introduce newlines that silently shift stored
positions. [4][9]

Capture a planner-profile revision and settings once per job; include it in
whole-chapter cache identity. Existing offline audio remains retained. Inner
segments may be reused only when their exact payload and synthesis semantics
are unchanged; profile changes that affect inference/context/silence belong in
their identity too. Never mutate an active generation's plan on pause, retry or
fallback. Preserve serial publication order, recovery points, generation fences,
16 MiB segment-audio ceiling and after-call cancellation semantics. [1][6][7]

**Then measure sizes separately.** Candidate steady budgets 480, 600, 700 and
800 with a common first target of 180 are an experimental matrix, not ranked
recommendations. Include old-boundary 180/800 and new-boundary 180/800 controls.
Use the same explicitly installed Faber artifact, voice options, runtime,
source ranges, device and cache conditions. The benchmark needs its own bounded
authorization; no new benchmark was performed here. [1][9]

## Evidence needed before adoption

- Rust planner tests: Portuguese prose/dialogue, paragraphs, headings/lists,
  abbreviations/decimals/quotes, long punctuation-free text, combining accents,
  emoji, empty input, capacities zero/one and protected terms at boundaries.
  Assert termination, ordered source coverage, valid coordinates and capacity.
- Parser/round-trip tests: canonical text and labels/TOC unchanged; valid,
  missing and malformed paragraph sidecars; nonzero Unicode offsets; backward
  compatibility with existing prepared text and EPUB/PDF inputs.
- Runtime tests: actual call sizes/session reuse, expansion, Piper failure and
  native fallback/recovery, cancellation/replacement during synthesis/cache/
  delivery, old-generation rejection, cache hit/miss/profile identity, valid
  receipts and completed artifacts. Source review is not runtime proof.
- IOS-06 tests/journeys: unavailable seek, exact boundary, in-chunk offset,
  backward retained seek, pause while buffering, replacement and file failure.
  Preserve requested seconds and pause intent using measured durations. [8]
- A separately authorized comparison: literal inputs, at most two selected
  chapters per book unless whole-book is explicit; record source/runtime/model
  hashes, active voice/fallback, cache state, first queued and audible audio,
  synthesis/real-time factor, segment duration distribution, joins/word
  completeness, cancellation delay, memory/storage and final persistence.
  Separate startup, inference, queue wait and transfer; do not sum overlapping
  intervals. Audible preference needs matched passages, not tier labels.

No material factual contradiction was found in the original source analysis.
This review adds two important qualifications: trimmed payload strings alone
cannot preserve exact source coordinates, and an oversized expanded speech
payload is resplit through `segments_with_limit`, whose own first sub-budget is
`min(180, limit)`, not simply one uniform `limit` per passage. [1][2]

The deliverable is a grounded proposal. Adoption and any changed size remain
pending measured evidence and the user's final decision; audible/visible native
acceptance is unexecuted. Required SE1/iOS 15.5 remains quarantined.

## Primary references

1. [Typed segmentation, recovery, expansion and publication](https://github.com/pietro1704/Epub-to-Mp3/blob/3396d04f7328d42fa410bb97be41854376e71161/crates/converter-core/src/worker/typed_speech_policy.rs) and [inner speech split](https://github.com/pietro1704/Epub-to-Mp3/blob/3396d04f7328d42fa410bb97be41854376e71161/crates/converter-core/src/platform_tts.rs).
2. [Current shared segmenter](https://github.com/pietro1704/Epub-to-Mp3/blob/3396d04f7328d42fa410bb97be41854376e71161/crates/converter-core/src/tts_session/text.rs).
3. [Literal pronunciation rules and protected ranges](https://github.com/pietro1704/Epub-to-Mp3/blob/3396d04f7328d42fa410bb97be41854376e71161/crates/converter-core/src/pronunciation.rs).
4. [EPUB canonical text projection](https://github.com/pietro1704/Epub-to-Mp3/blob/3396d04f7328d42fa410bb97be41854376e71161/crates/converter-core/src/epub/epub_chapter_content.rs).
5. [Pinned piper-rs `create`](https://github.com/thewh1teagle/piper-rs/blob/d70b0970a87453f3476b5fd6cf9edf329be8b445/src/lib.rs), [product provenance](https://github.com/pietro1704/Epub-to-Mp3/blob/3396d04f7328d42fa410bb97be41854376e71161/native/vendor/piper-rs/UPSTREAM.md), [eSpeak source buffer](https://github.com/pietro1704/Epub-to-Mp3/blob/3396d04f7328d42fa410bb97be41854376e71161/native/vendor/espeak-rs-sys/espeak-ng/src/libespeak-ng/translate.h#L44), [clause continuation](https://github.com/pietro1704/Epub-to-Mp3/blob/3396d04f7328d42fa410bb97be41854376e71161/native/vendor/espeak-rs-sys/espeak-ng/src/libespeak-ng/readclause.c), and [phonemizer wrapper](https://github.com/pietro1704/Epub-to-Mp3/blob/3396d04f7328d42fa410bb97be41854376e71161/native/vendor/espeak-rs/src/lib.rs).
6. [Native capabilities](https://github.com/pietro1704/Epub-to-Mp3/blob/3396d04f7328d42fa410bb97be41854376e71161/crates/converter-core/src/tts_session/catalog.rs) and [segment byte ceiling](https://github.com/pietro1704/Epub-to-Mp3/blob/3396d04f7328d42fa410bb97be41854376e71161/crates/converter-core/src/tts_session.rs).
7. [Chapter identity](https://github.com/pietro1704/Epub-to-Mp3/blob/3396d04f7328d42fa410bb97be41854376e71161/crates/converter-core/src/worker/tts_cache_identity.rs), [segment identity](https://github.com/pietro1704/Epub-to-Mp3/blob/3396d04f7328d42fa410bb97be41854376e71161/crates/converter-core/src/worker/segment_audio_cache.rs), and [generation-fenced callback](https://github.com/pietro1704/Epub-to-Mp3/blob/3396d04f7328d42fa410bb97be41854376e71161/crates/converter-core/src/worker/playback_chunk_delivery.rs).
8. [Unavailable-audio seek contract](https://github.com/pietro1704/Epub-to-Mp3/blob/3396d04f7328d42fa410bb97be41854376e71161/ios/EpubToMp3/docs/unavailable-audio-seek.md) and [measured-duration resolver](https://github.com/pietro1704/Epub-to-Mp3/blob/3396d04f7328d42fa410bb97be41854376e71161/ios/EpubToMp3/EpubToMp3/Features/Playback/Models/StreamedChapterSeek.swift).
9. [Listening source offsets/predictor](https://github.com/pietro1704/Epub-to-Mp3/blob/3396d04f7328d42fa410bb97be41854376e71161/crates/converter-core/src/tts_session/listening.rs) and [separate remote adaptive policy](https://github.com/pietro1704/Epub-to-Mp3/blob/3396d04f7328d42fa410bb97be41854376e71161/crates/converter-core/src/adaptive.rs).
10. [Unicode UAX #29 revision 49](https://www.unicode.org/reports/tr29/tr29-49.html), opened 2026-10-29: sentence and extended grapheme boundaries/tailoring. This is an implementation reference, not a performance result.
11. Historical task reference: Fabio Akita, *Competente o Suficiente*, 2026-10-14 EPUB edition, Appendix K. The preceding local assessment recorded a direct reading on 2026-10-28. This review checked that assessment, not the EPUB itself; this reference establishes task context rather than independently verified provider guidance.
