# Ubiquitous Language

## Library full-book download

A long press on a book in the Flutter Library exposes “Download all”. The
one-shot request opens the dedicated Convert destination and starts the full
book conversion with no chapter range. Each supported client uses the embedded
shared Rust converter locally. This is manual conversion and is separate from
Reader stream-on-demand, which is triggered only by Play.


The Reader screen must not expose a separate “Converter” action. Stream-on-
demand conversion starts only when the listener taps Play in the persistent
player. The play request first asks the active book screen to populate the
audio queue; only after a playable chapter is queued may playback start. Opening
a book never starts conversion or playback automatically. Full/manual
conversion remains available in the dedicated Convert destination.

## Shared Rust conversion runtime contract

All supported devices and clients — macOS, iOS, iPadOS, Android, Linux, and
Windows — must perform audiobook conversion through the same shared Rust
conversion code (`converter-core`/`converter-ffi`). The application embeds and invokes that Rust runtime locally; no external
HTTP backend or backend service of any kind is part of the product
runtime or required for conversion.

The Rust conversion boundary is model/provider agnostic. Model selection is a
runtime configuration concern: an online provider/model may be used when
configured, or an installed offline provider/model may be used when configured,
without changing the client contract or introducing a platform-specific
conversion implementation. The shared Rust layer owns job lifecycle, progress,
chapter artifacts, cancellation, errors, manifests, and streaming-ready audio.

Every client must expose the same behavior: on-demand playback starts when the
first validated audio is available, later chapters continue converting and are
queued progressively, and manual conversion is an explicit action using the
same Rust pipeline without autoplay. No backend service is part of the product
architecture.

This is a hard architecture invariant. Do not reintroduce an external backend,
platform-specific converter, or separate online/offline conversion pipeline.

## Narration pauses

Structural pauses are explicit segments of digital silence appended by the Rust worker
(`worker/heading_pauses.rs`) to the segment that ends the structural unit, never part of
the reader's text axis. Approved by Pietro (2026-11-23), totals measured with
`ffmpeg silencedetect` (`scripts/verify_narration_pauses.rb`): a paragraph boundary is
0.45 s with Piper and 0.55 s with the system voice (the explicit silence is the
difference to the voice's natural gap, 0.14 s / 0.30 s); a heading keeps 0.8 s; the end
of a chapter is 1.0 s; sentences keep the voice's own pacing. Each paragraph is its own
segment. The policy is part of the cache identity (`narration-pause-v1`), so audio made
without it is never reused. A narrated footnote gets 0.5 s (total) before its start marker
and after its end marker (see "Footnote narration").

## Footnote narration

Footnotes are read inline by default (approved by Pietro, 2026-11-23). The source text axis
never changes (highlight, seek and "follow the speech" use it); the Rust worker derives a
second, spoken text (`epub/footnote_narration.rs`): each note reference is followed by
"Início da nota de rodapé N." + the note + "Fim da nota de rodapé N." (en: "Footnote N." …
"End of footnote N."; es: "Nota al pie N." … "Fin de la nota al pie N."; other languages use
the English markers), set off by 0.5 s on both sides. A note whose body sits in the same
document is read at its reference and not again where it appears; a note from another
document is read from its extracted text. `N` is the reference label when it is a plain
number, else the note's position in the chapter. Chapters without notes narrate exactly as
before and keep their cache identity; chapters with notes add `narration-footnote-v1` (and
the spoken text itself) to it, so audio made without notes is never reused.

Contract for clients (additive, shared Rust):
- Preference `footnote_narration` in `TtsPreferences`: `"inline"` (default, not serialized)
  or `"skip"` (note bodies are left out of the narration; no markers).
- Each published audio segment carries its alignment passage in the ID3 `PRIV` tag. Source
  text passages keep `sourceOffset` (scalar offset in the chapter text). A narrated note is a
  passage with `"note": {"number", "sourceStart", "sourceEnd"}` and no `sourceOffset`: its
  text is the spoken note (markers included), not source text; `sourceStart..sourceEnd` is the
  note body in the chapter text when it lives there (highlight it and follow the speech
  there while the passage plays), or the empty range at the reference when the body is in
  another document. After the passage, highlighting returns to the next `sourceOffset`
  passage, which resumes right after the reference. Clients that ignore `note` skip the
  passage (no highlight), as they already do for passages they cannot place.
- `Chapter.note_marks` (Rust API): reference end, label, body text and, when in the same
  document, the body range, on the unchanged text axis.

## Streaming seek priority

When the listener navigates while streaming (a listening position or a playback window is set),
the destination is the top priority (card STREAM-SEEK-PRIORITY). `ConversionControl::prioritize`
(FFI `converter_job_control_prioritize`, unchanged signature) now also preempts: the chapter in
progress yields at its next segment boundary (`WorkerError::PlaybackWindowChanged`, requeued, its
finished segments stay in the segment cache) and the target is synthesized next; the preempted
chapter is resumed after it. The target must be eligible (with a listening plan the plan moves
onto it; with a playback window it must already be inside the window), otherwise it only
reorders the queue. Background jobs (no listening plan and no playback window, including jobs
without a control) rest at their segment boundaries while the target has not delivered its first
segment, bounded by 30 s and by cancellation. `converter_job_control_chapter_is_preempted(control,
chapter) -> bool` (additive) lets chunk-delivery adapters drop in-flight chunks of a chapter that
must yield. Seeks through `set_listening_position` already preempted and still do.

## Book language profile

The detector reads the WHOLE book once (not 32 samples) and classifies it
(`language/profile.rs`, card BOOK-LANGUAGE-PROFILE): `monolingual` (quotations in other languages
do not count: a language belongs to the book only when it is at least 10% of the detected text or
fills one uninterrupted section of about a page), `bilingual` (two languages, parallel text or
alternating sections) or `multilingual` (three or more, by section), with each language's share.
The profile is cached by the book's source identity (`language-profile-v1.json`), computed in the
job set-up and never in the segment loop. A monolingual book is narrated entirely with the voice
of its main language: no passage is routed to another language, so a quotation never stops the
playback or asks for another model. In a bilingual or multilingual book, the main voice speaks the
first of the book's languages it can; a passage in a language without a voice (and without a
language-compatible secondary voice) is read with the main voice and playback continues. The
profile and the detector are part of the narration cache identity (`book-language-profile-v1`).

Contract for clients (additive): `converter_book_language_analysis_json_v1(path)` keeps its
payload and adds `profile`: `{version, detector, class: "monolingual"|"bilingual"|"multilingual",
primary, languages: [{language, chars, fraction, longest_section_chars}], incidental: [language],
total_chars, undetermined_chars}`. A client warns BEFORE playing which models are missing by
resolving each `languages[].language` with the existing language-model-resolution contract
(installing a model stays an explicit action).

## Provider feedback

**Provider pressure**:
A TTS provider's signal that current request size or rate exceeds its present capacity, including throttling, timeouts, and sustained slow responses.
_Avoid_: generic conversion failure

**Adaptive throughput**:
The conversion run's observed characters-per-second and provider pressure, used to keep remote request size and concurrency near the fastest reliable operating point.
_Avoid_: fixed concurrency tuning

The accepted runtime policy and measured starting profile are recorded in
[`docs/adr/2026-10-07-adaptive-tts-throughput.md`](docs/adr/2026-10-07-adaptive-tts-throughput.md).

## Repository trust surface

The collection of repository-facing automation, documentation, hooks, and
governance that contributors rely on to make and review changes safely.

## Evidence gate

The reviewable proof required before an issue may be closed: applicable local
validation, CI evidence for the exact commit, and any platform-specific
validation that the change requires.

## Wiki publication contract

The explicit safety boundary for synchronizing versioned documentation to the
external GitHub Wiki: preflight, displayed external diff, confirmation, and
recoverable failure behavior.

## Product runtime change

A change to user-facing application behavior, such as the macOS embedded
runtime. It is not a repository trust-surface change and requires product
validation on its own delivery path.

## Progressive playback

Playback of audiobook chapters as their audio becomes available during a
conversion, without waiting for the complete book.

## Offline listening cache

The durable local collection of audio chapters that have been played or
explicitly downloaded. It is retained so playback remains available offline,
including when a listener completes a book through progressive playback without
requesting a separate full download. It is protected from automatic TTL and LRU
eviction; only the listener removes it.

A chapter enters this cache when playback of its first streamed segment becomes
audible; its incoming segments are assembled into the chapter's final audio
file. If conversion is interrupted after that point, the durable-retention
intent persists until a valid final file is available or the listener removes
the download.

## Rebuildable performance cache

Derived reader text, normalized PDF pages, partial audio buffers, and completed
conversion artifacts that reduce latency but can be reconstructed. It has its
own bounded LRU-and-TTL budget and never evicts Offline listening cache content.

## Playback-first resource policy

The rule that reading, a pending navigation, and audible playback take priority
over conversion throughput. Conversion yields under interaction, low-power,
memory-pressure, or thermal conditions, then resumes aggressive use only after
the listener-visible path is stable.

## Warm book open

Reopening an imported book whose reader content and playback state have already
been prepared. A warm open restores readable content, the saved reading
position, and usable audio controls without reparsing the source document or
reconstructing the playback session.

Warm opens persist across app relaunches until the listener removes the book.
They are an Apple-client contract for iPhone, iPad, and macOS. The target is a
perceptually instant open: readable content and audio controls within 200 ms.

## Cold book open

The first open of an imported book, when the source document has not yet been
prepared for the reader. Cold-open work may continue in the background after
the reader becomes usable, but it must establish the assets required by later
warm opens.

## Performance program

A cross-client effort to improve observable application speed through explicit
latency budgets. It sequences the Apple clients and shared Rust conversion
runtime before the web and Flutter clients, and prioritizes perceived readiness
and playback stability. Conversion may use available CPU and memory
aggressively only while it does not degrade reading or playback responsiveness.

## Latency observation

A monotonic, correlated record of one listener-visible transition: the
initiating gesture, the relevant ready state, and the elapsed time between
them. The same vocabulary applies across clients; for streaming playback it
keeps audio queued and audio audible as distinct ready states.

## Navigation seek

Playback controls that seek a fixed interval within the current chapter and
navigate to the previous or next chapter at its boundaries.

The forward and backward intervals are independently configurable as 15, 30,
45, or 60 seconds. The selected values apply consistently to the mini player,
expanded player, system widget and Lock Screen controls.

Both intervals default to 15 seconds and persist independently across app
launches.

## Pending navigation

A requested seek or chapter transition whose target audio is not yet available
during progressive playback. The request is retained, the target becomes the
highest conversion priority, and playback starts automatically when its first
segment is available.

## Chrome-stable reader viewport

The reader's text geometry stays at its chrome-free, physical-safe-area size
while navigation and playback controls appear as overlays. Chrome visibility
preserves page boundaries, the reading anchor and the exact raw `contentOffset`
of the active text surface. Explicit page turns use canonical page offsets;
typography and actual window-size changes can establish a new text geometry.

## Reader text viewport

The final visible text presentation for one committed reader geometry. It
preserves the reading anchor while exposing page, clipping, and fallback facts
for the active text surface.

## Verified book structure

The chapter tree used for conversion, derived preferentially from the source
book's table of contents. Verification checks that TOC entries map to readable
content, titles and order are preserved, invalid anchors or pages are reported,
and relevant unmapped content is surfaced before synthesis.

## Structure fallback

An explicitly reported chapter tree derived from the source EPUB/PDF/HTML
structure when automatic TOC extraction is incomplete or unavailable. It is
shown for review and requires confirmation only when verification produces
warnings.

## Local conversion

Book ingestion, structure verification, text preparation, TTS, chapter audio,
manifest persistence, and playback performed on the client device without a
backend requirement. Piper Faber is the default primary narration provider;
installed platform speech is the default fallback. Online Edge narration requires
explicit selection or consent. A model is never downloaded implicitly. The
actually active provider and voice remain distinguishable from the configured
primary while fallback is in use.

## Playback snapshot

The immutable, versioned state published by the central playback coordinator.
Every playback surface consumes it instead of reading the player, background
callbacks, conversion events, or persistence directly. It includes confirmed
playing/loading state, chapter, position, duration, speed, and a monotonic
revision.

## Playback coordinator

The sole owner of playback state reconciliation for one process. It accepts
commands, observes the real player, publishes playback snapshots, and rejects
or supersedes stale/conflicting operations. UI controls emit intent only.

## Rehydratable state

Persisted playback or conversion state that can be checked against real
artifacts and reconciled after relaunch. Transient states such as playing,
loading, and converting are never trusted without live confirmation.
