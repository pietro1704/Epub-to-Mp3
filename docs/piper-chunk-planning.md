# Source-aware speech chunk planning

The shared Rust planner retains the native worker's nominal 180-scalar first
budget and 800-scalar steady budget, bounded by captured adapter capabilities.
This change does not establish an optimal Piper size or change inference options.

Within a budget, prefer a nearby paragraph end, then a complete sentence.
Retain an earlier complete boundary when no complete boundary exists in the
latter half. Otherwise use a clause/word boundary and finally a whole extended
grapheme. Sentence boundaries use [Unicode segmentation](https://docs.rs/unicode-segmentation/1.13.3/unicode_segmentation/trait.UnicodeSegmentation.html)
with common Portuguese abbreviation/initial tailoring and contextual punctuation
checks. These rules are bounded heuristics, not a complete language parser.
A grapheme that cannot fit the capacity is rejected rather than split.

EPUB block boundaries are projected as paragraph-end sidecars onto the existing
normalized Unicode-scalar text axis. Canonical text, heading labels, chapter
identity, TOC order and reader offsets remain unchanged. Missing paragraph data
uses sentence/word planning. Invalid, duplicate, unordered or out-of-range
sidecars fail closed.

Every planned source span retains its exact bytes and scalar range, including
consumed whitespace. Synthesis trims only the payload's outer whitespace.
Protected pronunciation terms move a cut before the term where possible;
otherwise the whole term is retained. Protection expands to grapheme edges.
Source budgets remain soft for protected terms; expanded speech is checked and
resplit against the actual adapter capacity. No punctuation or silence is added.
Fallback subdivisions rebase their ranges onto the parent span, so progress
counts consumed source rather than reconstructing it from trimmed strings.

The `text-v2-sentence-paragraph-grapheme` profile participates in whole-chapter
cache identity. Existing audio/download files are not deleted by this change.
Inner segments retain exact source-payload, spoken-payload and runtime identity.
Planning stays serial under the existing captured recovery policy; cancellation,
replacement, generation fences and measured-duration seek behavior are unchanged.

The converter-core workspace suite covers planner range/coverage properties,
Portuguese punctuation, Unicode graphemes, protected terms, paragraph projection,
real worker dispatch/progress/artifacts, legacy profile invalidation, and the
existing cancellation/fallback/cache contracts. Run its Rust gate on an
authorized build platform under the execution policy. Audible quality and sizing
claims require separate same-input runtime evidence; unit tests do not establish
a preferred voice, latency improvement or natural-sounding joins.
