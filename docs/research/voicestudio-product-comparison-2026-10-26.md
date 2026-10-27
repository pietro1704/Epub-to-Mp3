# VoiceStudio inspiration: current EpubToMp3 comparison

Date: 2026-10-26. Source review only; no application, build, test, synthesis,
model download or benchmark was run. This report remains local.

## Snapshot and correction to the earlier status

VoiceStudio main was inspected at
[`303cbee8066288c8dfbea2787230abdd2dc8c9d3`](https://github.com/debpalash/VoiceStudio/tree/303cbee8066288c8dfbea2787230abdd2dc8c9d3).
The previous review used `219e5072f6ea3b4a219c59372cb443892b3296b2`.

EpubToMp3 local master and the read-only remote master lookup both identify
`8fb38e4e47e4b78b5559d6068cc1f664e690c9dc`. The original checkout is still at
`f4546e669852e50602d893e9e8b603511e1a90b6` with unrelated local edits. Comparing
only that checkout would incorrectly classify delivered work as missing.

The following model-library work is already integrated in master, established
by Git history and source inspection (not a fresh CI or app acceptance run):

| Capability | Integrated change | Owning source |
| --- | --- | --- |
| Authoritative versioned catalogue | #950 | `crates/converter-core/src/speech_model_library.rs` |
| Installed integrity versus runtime readiness | #951 | `speech_model_library/inspection.rs`, `model_store/model_inspection.rs` |
| Native factual model labels | #952 | `SpeechModelLibraryClient.swift`, `SpeechModelSnapshot.swift` |
| Cancellable background installation | #955 | `model_store/model_install_operation*`, `SpeechModelBackgroundTransfer.swift` |
| Explicit install/select/remove actions | #956 | `SpeechModelLibraryViewState.swift`, `MacSpeechModelLibraryPanel.swift` |

The separate `epubtomp3-tts-benchmark` worktree is on
`feat/model-download-resume-20261026`, based at `3a700a1666`, with uncommitted
range-download recovery, additional Piper voices, presentation consolidation
and native test sources. These are implementation candidates, not accepted
deliveries. `ios/EpubToMp3/docs/model-download-resume.md` describes the candidate;
`docs/research/2026-10-26-piper-voice-audit/README.md` separates upstream artifact
and licence evidence from runtime acceptance.

## Most useful adaptations

| Priority | VoiceStudio source evidence | Adaptation for EpubToMp3 | Acceptance needed |
| --- | --- | --- | --- |
| First | [ModelsView.swift](https://github.com/debpalash/VoiceStudio/blob/303cbee8066288c8dfbea2787230abdd2dc8c9d3/mobile/ios/VoiceStudio/Features/ModelsView.swift) shows size, installation progress/cancel, licence review and memory-fit feedback. | Finish the existing model-library slice: clear names, exact language, installed/ready state, download versus select, and actionable failure. Add filtering/grouping when the catalogue grows. Avoid another catalogue implementation. | Actual native list/install/cancel/retry/select/remove journeys; preserved selections and existing artifacts on failure. Source existence alone is insufficient. |
| Next | [longform_progress.py](https://github.com/debpalash/VoiceStudio/blob/303cbee8066288c8dfbea2787230abdd2dc8c9d3/backend/services/longform_progress.py) weights chapter work by characters and estimates throughput from a rolling window of fresh chunks. Cache hits advance completion without inflating synthesis rate. | Show distinct preparing voice, generating, playable, buffering, completed and failed states. Estimate export completion from measured fresh synthesis; expose listening buffer separately. Extend existing progress and latency observations. | Unknown ETA before evidence; cache-only and mixed runs; unequal chapters; failure/cancel/replacement; stalls and changing generation speed. Never convert a failed chapter into successful completion. |
| Next | [longform_render.py](https://github.com/debpalash/VoiceStudio/blob/303cbee8066288c8dfbea2787230abdd2dc8c9d3/backend/services/longform_render.py) implements chapter and inner per-segment caches; [audiobook router](https://github.com/debpalash/VoiceStudio/blob/303cbee8066288c8dfbea2787230abdd2dc8c9d3/backend/api/routers/audiobook.py) wires both into generation. | Reuse verified individual synthesis blocks after interrupted chapters or a nearby seek. Keep chapter artifacts as the outer fast path. Current progressive chunks and receipts do not by themselves establish a persistent content-addressed segment cache. | Compare actual seek/restart reuse first. New identity must include normalized text, preprocessing version, exact model/runtime/voice/options and actual fallback identity. Corruption is a cache miss; obsolete jobs cannot publish. Bound storage and preserve anchor mapping. Benefit remains unmeasured. |
| Later | [pronunciation.py](https://github.com/debpalash/VoiceStudio/blob/303cbee8066288c8dfbea2787230abdd2dc8c9d3/backend/services/pronunciation.py) applies literal respellings with boundaries and stable lexicon signatures. | Optional pronunciation corrections for names, abbreviations and foreign words, scoped to a book/language. Preserve the displayed EPUB text; transform synthesis input in Rust and retain source-to-speech mapping. | Unicode boundaries, overlapping terms, nonrecursive replacement, dictionary identity invalidation, page/seek alignment and cancellation. Retain existing audio until replacement is validated. |
| Later | [AudiobookTab.jsx](https://github.com/debpalash/VoiceStudio/blob/303cbee8066288c8dfbea2787230abdd2dc8c9d3/electron/src/shared/pages/AudiobookTab.jsx) has persistent voice assignment, chapter preview and chapter-level render feedback. | A short explicit audition of an installed voice before selecting it, then optional per-book voice choice. This is a recommendation inspired by preview workflows, not a claim that VoiceStudio's model list has a universal audition button. | Audition does not alter global selection, book position, running job or library artifacts; stop/cancel reliably. A remote sample must be labelled as a sample rather than local inference. |

## What already fits the existing architecture

Two further product patterns deserve adaptation:

- [AudiobookRecovery.jsx](https://github.com/debpalash/VoiceStudio/blob/303cbee8066288c8dfbea2787230abdd2dc8c9d3/electron/src/shared/components/audiobook/AudiobookRecovery.jsx)
  presents interrupted work in the book's context. A suitable EpubToMp3 card is
  “Conversion interrupted — 8 of 20 chapters ready — Resume”. Derive it from
  verified Rust job/artifact state and reject stale inventory callbacks; do not
  expose private cache paths in ordinary product UI.
- [AudiobookBookPanel.jsx](https://github.com/debpalash/VoiceStudio/blob/303cbee8066288c8dfbea2787230abdd2dc8c9d3/electron/src/shared/components/audiobook/AudiobookBookPanel.jsx)
  gives output format prominence and collapses advanced details. Preserve the
  simple reader/listen path and expose export configuration separately. The
  [result view](https://github.com/debpalash/VoiceStudio/blob/303cbee8066288c8dfbea2787230abdd2dc8c9d3/electron/src/shared/components/audiobook/AudiobookResult.jsx)
  reports failures but can still say ready with failed chapters: EpubToMp3 should
  explicitly distinguish complete from partial and offer retry for missing work.

EpubToMp3 already has process-resident Piper state in
`native/piper-runtime/src/lib.rs`, session reuse in
`crates/converter-core/src/worker/typed_speech_policy.rs`, chapter cache validation
in `worker/chapter_execution.rs`, and model/runtime/text identity in
`worker/tts_cache_identity.rs`. Its `tts_session/listening.rs` already prioritizes
the requested text position and gates next-chapter prefetch using remaining audio,
playback rate and observed generation time. Do not create a second scheduler.

`LatencyObservationStore.swift` already distinguishes play request, audio queued
and audio audible transitions, and separates producer timing from client timing.
Improve and verify this existing path instead of adding an unrelated telemetry
framework. A recorded player event still does not prove physical first sound.

VoiceStudio's [engine_memory.py](https://github.com/debpalash/VoiceStudio/blob/303cbee8066288c8dfbea2787230abdd2dc8c9d3/backend/services/engine_memory.py)
keeps one heavy TTS engine resident by default and avoids evicting engines in use.
For EpubToMp3, retain warm reuse of the current model; investigate bounded idle
release or memory-pressure handling only if measurements justify it. Never unload
an in-use model or confuse storage availability with sufficient inference RAM.

## Important differences and traps

- **Exact language:** new [language_variants.py](https://github.com/debpalash/VoiceStudio/blob/303cbee8066288c8dfbea2787230abdd2dc8c9d3/backend/core/language_variants.py)
  distinguishes PT-BR/PT-PT while routing through a base engine language. Useful
  UI vocabulary, but a default `pt` to `pt-BR` mapping is not evidence a model
  supports that dialect. Preserve EpubToMp3's exact language-evidence fields.
- **Rate units:** `longform_progress.py` calls audio-seconds/wall-seconds `rtf`;
  [benchmarks.md](https://github.com/debpalash/VoiceStudio/blob/303cbee8066288c8dfbea2787230abdd2dc8c9d3/docs/benchmarks.md)
  defines RTF as compute/audio, its inverse. Adopt explicit names and units. The
  inspected benchmark table still contains no verified result rows.
  [GenerationProgress.jsx](https://github.com/debpalash/VoiceStudio/blob/303cbee8066288c8dfbea2787230abdd2dc8c9d3/electron/src/shared/components/audiobook/GenerationProgress.jsx)
  still derives ETA from completed chapters; improved backend math does not
  establish that every UI consumes it. Verify the entire event-to-screen path.
- **Mobile lifecycle:** [VSNative.c](https://github.com/debpalash/VoiceStudio/blob/303cbee8066288c8dfbea2787230abdd2dc8c9d3/mobile/ios/VoiceStudioKit/Sources/VSNative/VSNative.c)
  still creates/destroys the Sherpa TTS engine within each synthesis call. Desktop
  warm-engine behavior cannot be assigned to this mobile path.
- **Deployment:** [VoiceStudioKit/Package.swift](https://github.com/debpalash/VoiceStudio/blob/303cbee8066288c8dfbea2787230abdd2dc8c9d3/mobile/ios/VoiceStudioKit/Package.swift)
  requires iOS 17/macOS 14. EpubToMp3 retains iOS 15.5 acceptance requirements.
  Electron, Python sidecars and MLX/MPS implementations are not direct adapters
  for this native Swift/Rust app or its Intel Mac target.
- **Licensing:** VoiceStudio's [LICENSE](https://github.com/debpalash/VoiceStudio/blob/303cbee8066288c8dfbea2787230abdd2dc8c9d3/LICENSE)
  is AGPLv3; EpubToMp3 declares MIT. Independently implement ideas. Any source
  incorporation requires an explicit licensing assessment; model and dataset
  rights remain separate. A consent button cannot grant absent rights.
- **Model selection:** variety of ready-made voices is the established goal.
  Finish the audited optional Piper voices before adding another runtime. Neither
  VoiceStudio's engine count nor a model's disk size proves speed, pronunciation
  quality, peak RAM or supported-device compatibility. Keep Faber primary and
  truthful system fallback under current project policy.

## Recommended sequence

1. Reconcile and validate the existing phase-6/voice/presentation candidates;
   avoid restarting phases 1–5 or overwriting either dirty worktree.
2. Complete a coherent native voice-library journey with ready-made voices and
   truthful configured-versus-active fallback feedback.
3. Improve per-chunk progress/ETA through the existing Rust event boundary.
4. Characterize repeated seek/interrupted-chapter reuse; add inner segment cache
   only where that evidence establishes a gap.
5. Add optional audition and pronunciation controls as separate product slices.

No implementation was requested by this review. No new provider/default change,
model installation, benchmark, CI pass or native visual acceptance is claimed.
Simulator remains quarantined and Android remains paused.
