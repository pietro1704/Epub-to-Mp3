# VoiceStudio: what can be reused in EpubToMp3

Date: 2026-10-25

## Executive conclusion

VoiceStudio does not currently provide evidence for replacing Piper as the
EpubToMp3 default in order to make Portuguese synthesis faster. On the contrary,
the closest directly measured evidence in this repository still favors Piper
Faber: on a physical iPhone 16e it generated the 655-character Portuguese
fixture in 2.43 s (RTF 0.065, 343 MiB peak RSS), compared with 7.29 s for Pocket
Portuguese, 19.08 s for Supertonic 3 and 33.68 s for Kokoro. These measurements
are not iPhone SE results, quality rankings or end-to-end app timings, but they
are stronger mobile evidence than VoiceStudio's currently empty published
benchmark table.

The most valuable ideas to reuse are architectural, not model weights or source
code:

1. a richer, versioned model catalogue containing checksums, exact revisions,
   memory requirements, languages, speaker IDs and licence fingerprints;
2. persistent cache at segment level, so editing one sentence does not
   regenerate a chapter;
3. an explicit resident-engine policy and cold/warm/first-playable-audio
   telemetry;
4. truthful runtime/device reporting instead of inferring acceleration from the
   selected model;
5. voice lists driven by model metadata, with language and speaker validation.

Those concepts should be independently implemented in the Rust-owned runtime.
VoiceStudio itself is AGPL-3.0-only, while EpubToMp3 declares MIT, so copying
implementation code into this repository would require an explicit licensing
decision. Model weights and phonemizer assets also have their own terms.

No model was downloaded and no build, synthesis, quality test or benchmark was
run for this review. Recommendations marked **hypothesis** require experiments;
they are not presented as established gains.

## Scope and evidence

- VoiceStudio was inspected at `main` commit
  [`219e5072f6ea3b4a219c59372cb443892b3296b2`](https://github.com/debpalash/VoiceStudio/tree/219e5072f6ea3b4a219c59372cb443892b3296b2).
- EpubToMp3 was inspected at commit `f4546e669852e50602d893e9e8b603511e1a90b6`.
- Primary evidence is VoiceStudio source/documentation at that pinned commit and
  EpubToMp3 source plus its retained physical-device benchmark reports.
- The pinned source snapshot, rather than a mutable branch or release headline,
  is used for all code claims.
- The review focuses on offline TTS speed, memory, voice/model choice, mobile
  compatibility, caching and licensing. Voice cloning is considered only where
  it could affect audiobook use.

The comparison deliberately separates three kinds of evidence:

- **Measured here:** retained EpubToMp3 benchmark output produced by actual
  execution.
- **Implemented:** behavior observable in source, but not necessarily measured
  on the EpubToMp3 target device.
- **Claimed upstream:** a statement in VoiceStudio documentation, which is not a
  local reproduction.

## The architectural comparison that matters

### VoiceStudio desktop

VoiceStudio desktop is primarily a Python backend with Electron UI and multiple
in-process or sidecar engines. Its performance strategy includes lazy model
loading, warm sidecar reuse, cached voice-clone prompts, configurable idle
unload, one resident TTS engine by default, and device/runtime reporting. Its
documentation says the first load is normally the slowest, model weights load
lazily, and warm generations should be used when assessing steady-state speed
([performance lines 22–43](https://github.com/debpalash/VoiceStudio/blob/219e5072f6ea3b4a219c59372cb443892b3296b2/docs/performance.md#L22-L43)).

The resident-engine policy is real source behavior, not merely a UI setting:
before an engine is selected it unloads other cached TTS engines, unless the
policy is disabled
([engine_memory.py lines 1–17](https://github.com/debpalash/VoiceStudio/blob/219e5072f6ea3b4a219c59372cb443892b3296b2/backend/services/engine_memory.py#L1-L17),
[lines 65–110](https://github.com/debpalash/VoiceStudio/blob/219e5072f6ea3b4a219c59372cb443892b3296b2/backend/services/engine_memory.py#L65-L110)).
Long-lived sidecars also reuse warm sessions; for example, Supertonic explicitly
does so
([supertonic3.md lines 50–54](https://github.com/debpalash/VoiceStudio/blob/219e5072f6ea3b4a219c59372cb443892b3296b2/docs/engines/supertonic3.md#L50-L54)).

This desktop behavior cannot be treated as mobile evidence. MLX-Audio, Python
sidecars and Apple-Silicon MPS paths do not fit EpubToMp3's native iOS 15/Rust
runtime merely because they run on a Mac.

### VoiceStudio mobile

VoiceStudio's iOS package requires iOS 17 and macOS 14
([Package.swift lines 4–16](https://github.com/debpalash/VoiceStudio/blob/219e5072f6ea3b4a219c59372cb443892b3296b2/mobile/ios/VoiceStudioKit/Package.swift#L4-L16)).
EpubToMp3 targets iOS 15.0 in its build configuration, and the project's required
reader acceptance target is iOS 15.5. Therefore, direct compatibility is not
established.

The mobile app serializes native inference through a process-wide lease because
concurrent models exceeded phone memory in its testing
([LocalEngine.swift lines 108–123](https://github.com/debpalash/VoiceStudio/blob/219e5072f6ea3b4a219c59372cb443892b3296b2/mobile/ios/VoiceStudioKit/Sources/VoiceStudioKit/Local/LocalEngine.swift#L108-L123)).
That memory discipline is sensible. However, the native shim currently creates
and frees the Sherpa TTS engine inside every `vs_synthesize` call
([VSNative.c lines 58–75](https://github.com/debpalash/VoiceStudio/blob/219e5072f6ea3b4a219c59372cb443892b3296b2/mobile/ios/VoiceStudioKit/Sources/VSNative/VSNative.c#L58-L75))
and creates/frees the OmniVoice model and context inside every corresponding
call
([VSNative.c lines 202–248](https://github.com/debpalash/VoiceStudio/blob/219e5072f6ea3b4a219c59372cb443892b3296b2/mobile/ios/VoiceStudioKit/Sources/VSNative/VSNative.c#L202-L248)).
The Swift actor and lease make execution safe and cancellable, but they do not
make the native model resident.

This is the central caution in the comparison: VoiceStudio desktop's warm-engine
performance model is not the architecture of VoiceStudio iOS. Reusing the mobile
shim literally would probably regress repeated synthesis startup versus
EpubToMp3's current Piper runtime.

### EpubToMp3 today

EpubToMp3 already implements several optimizations that VoiceStudio documents:

- `native/piper-runtime/src/lib.rs` keeps Piper runtime state inside the process
  and makes initialization idempotent for the same model identity.
- `crates/converter-core/src/worker/typed_speech_policy.rs` reuses a speech
  session within a job/selection and emits progressive chunks rather than
  waiting for a whole book.
- `crates/converter-core/src/worker/chapter_execution.rs` caches completed
  chapter artifacts.
- `crates/converter-core/src/worker/tts_cache_identity.rs` includes text and TTS
  selection identity in cache decisions.
- the current speech path already uses bounded text chunks, with 800 characters
  as the relevant default in the inspected path. VoiceStudio independently uses
  an 800-character default and 50 ms crossfade
  ([chunked_tts.py lines 29–33](https://github.com/debpalash/VoiceStudio/blob/219e5072f6ea3b4a219c59372cb443892b3296b2/backend/services/chunked_tts.py#L29-L33));
  the number alone is not a reason to change EpubToMp3.

The clearest missing layer is persistent, reusable **segment** output. The
current chapter cache is valuable for unchanged chapters, but a small edit can
invalidate a much larger artifact than necessary.

## Reuse decision matrix

| VoiceStudio idea or component | Decision | Why |
| --- | --- | --- |
| Rich mobile model manifest | **Reimplement now** | It carries exact revision, SHA-256, byte size, runtime, RAM floor, language list, speaker count/IDs and licence acceptance metadata. This improves safety and future voice selection without adopting a new model. |
| Segment-level PCM cache | **Adapt at high priority** | VoiceStudio hashes configuration, voice, speed, pause and text, persists each segment, and assembles from disk ([Production.swift lines 121–181](https://github.com/debpalash/VoiceStudio/blob/219e5072f6ea3b4a219c59372cb443892b3296b2/mobile/ios/VoiceStudioKit/Sources/VoiceStudioKit/Local/Production.swift#L121-L181)). This can reduce repeat/edit work, although the exact benefit is not yet measured in EpubToMp3. |
| Single resident-engine policy | **Adapt** | Useful when multiple local engines are installed; prevents RAM stacking. EpubToMp3 should preserve one explicitly selected warm engine per active job and unload on pressure/bounded idle, rather than reload per sentence. |
| Cold/warm/TTFA/RTF telemetry | **Adopt** | Needed to tell load time, synthesis time and first playable audio apart. VoiceStudio's streaming route records TTFA/RTF, but published benchmark results are absent. |
| Runtime/device truth in UI/logs | **Adopt** | Report actual CPU/Metal/runtime and active voice. It avoids calling a path accelerated merely because the model theoretically supports a device. |
| Speaker IDs from the catalogue | **Adapt carefully** | Can expose multiple preset voices where the exact artifact and runtime already support `sid`; language, pronunciation and licence still need validation. |
| Voice-clone prompt cache | **Defer** | Useful only after a cloning model is accepted. It does not accelerate Piper preset voices. |
| Mobile `NativeLease` serialization | **Concept already applicable** | One heavy inference at a time is appropriate for constrained phones, but EpubToMp3 already has a shared execution lease/session policy. Compare semantics before adding another lock. |
| VoiceStudio mobile C shim | **Do not reuse as-is** | It recreates heavy native TTS state per call and targets iOS 17. |
| Python sidecars in the Apple apps | **Reject** | They conflict with the project's Rust-owned native runtime and would not be a valid iOS deployment architecture. |
| MLX-Audio integration | **Reject for the shared Apple runtime** | It is a Python/Apple-Silicon desktop route, does not support Intel Mac, and does not establish iOS 15.5 compatibility. |
| Source-code copying | **Do not do without a licence decision** | VoiceStudio is AGPL-3.0-only; EpubToMp3 is MIT. Independently implementing an idea from observed behavior is different from copying code. |

## Speed findings

### What is actually measured in this project

The retained physical-device campaign used the same Portuguese short and
655-character fixtures for all offline candidates, three attempts each. The
paragraph medians were:

| Exact tested candidate | File-ready time | RTF | Peak process RSS | Result |
| --- | ---: | ---: | ---: | --- |
| Piper Edresson low, FP32, 2 CPU threads | 2.15 s | 0.046 | 327 MiB | 6/6; pronunciation warning |
| **Piper Faber medium, FP32, 2 CPU threads** | **2.43 s** | **0.065** | **343 MiB** | **6/6** |
| Pocket Portuguese 6-layer, mixed INT8/FP32 | 7.29 s | 0.220 | 1,190 MiB | 6/6 |
| Supertonic 3 INT8, 8 steps, `sid=0`, `lang=pt` | 19.08 s | 0.346 | 585 MiB | 6/6 |
| Kokoro v1.0 multilingual INT8, Dora `sid=42`, `lang=pt-br` | 33.68 s | 0.852 | 523 MiB | 6/6 |

Source: [physical iPhone benchmark](2026-10-14-tts-phone-benchmark.md).
The device was an iPhone 16e on iOS 27.0.1, not the required iPhone SE/iOS 15.5
acceptance target. No blind listening/MOS, pronunciation score, battery,
thermal, sustained-book or speaker-playback timing was measured. The results do
not establish Core ML or Metal performance for untested variants.

The consolidated Mac/book campaign likewise kept Piper Faber as the primary
offline candidate and did not establish Pocket as a better PT-BR default
([consolidated benchmark](2026-10-23-tts-benchmark.md)). Its configurations and
timing boundaries differ from the phone test, so values must not be mixed into a
single ranking.

### What VoiceStudio publishes

VoiceStudio defines RTF correctly and contains a comparison table, but that
table has no result rows at the inspected commit
([benchmarks.md lines 22–36](https://github.com/debpalash/VoiceStudio/blob/219e5072f6ea3b4a219c59372cb443892b3296b2/docs/benchmarks.md#L22-L36)).
Therefore it supplies no reproducible published basis for claiming that one of
its engines beats Piper on the EpubToMp3 device and workload.

VoiceStudio says PocketTTS reaches roughly 8–9x real-time on an Apple M3 Pro
([pockettts.md lines 1–11](https://github.com/debpalash/VoiceStudio/blob/219e5072f6ea3b4a219c59372cb443892b3296b2/docs/engines/pockettts.md#L1-L11)).
That is an upstream desktop claim, not a phone result. EpubToMp3's physical-phone
measurement is the more relevant evidence for the current product.

### Where speed may still improve without changing the model

The current integrated Piper path has several measurable candidates for
optimization before a new model is introduced:

- the outer speech policy caps every provider at 800 characters and keeps the
  policy/session guards across the chapter loop
  ([typed_speech_policy.rs lines 98–141](https://github.com/pietro1704/Epub-to-Mp3/blob/f4546e669852e50602d893e9e8b603511e1a90b6/crates/converter-core/src/worker/typed_speech_policy.rs#L98-L141));
- every Piper segment enters the process-wide model transaction, revalidates
  the model/config, calls the otherwise idempotent runtime initialization and
  creates a temporary WAV directory
  ([piper_model_preparation.rs lines 185–218](https://github.com/pietro1704/Epub-to-Mp3/blob/f4546e669852e50602d893e9e8b603511e1a90b6/crates/converter-core/src/piper/piper_model_preparation.rs#L185-L218));
- that validation rereads and reparses the model JSON
  ([piper_quality_policy.rs lines 5–34](https://github.com/pietro1704/Epub-to-Mp3/blob/f4546e669852e50602d893e9e8b603511e1a90b6/crates/converter-core/src/piper/piper_quality_policy.rs#L5-L34)); and
- the native adapter creates another per-segment staging directory and reads
  the WAV back into memory
  ([native_tts_adapters.rs lines 215–245](https://github.com/pietro1704/Epub-to-Mp3/blob/f4546e669852e50602d893e9e8b603511e1a90b6/crates/converter-core/src/worker/native_tts_adapters.rs#L215-L245),
  [lines 310–340](https://github.com/pietro1704/Epub-to-Mp3/blob/f4546e669852e50602d893e9e8b603511e1a90b6/crates/converter-core/src/worker/native_tts_adapters.rs#L310-L340)).

These are source-level overhead candidates, not proven dominant bottlenecks.
Instrument them before changing safety checks. In particular, benchmark the
integrated `piper-rs` path at 800/2,000/5,000-character boundaries and compare
it with Piper through the already used Sherpa-ONNX 1.13.8 runtime, using the
same Faber artifact, text, output validation and thread counts. This would show
whether to optimize validation/staging around the current runtime or change the
runtime implementation. Increasing segment size or concurrency without this
evidence could worsen first-audio latency, cancellation responsiveness or
memory use.

1. **Segment reuse — hypothesis, high confidence in direction.** Persist final
   per-segment PCM/audio with a complete identity. Repeat conversion and local
   edits should synthesize only missing segments. The size of the win depends on
   actual user edit/retry patterns and needs telemetry.
2. **First-playable scheduling — hypothesis.** Prioritize the block at the
   user's current reading position, then nearby blocks and the next chapter.
   This can reduce perceived waiting without changing total synthesis time.
3. **Measure cold and warm separately.** Record app request, model load, first
   PCM callback, first non-silent PCM, persisted chunk, player-ready and final
   export. A single “generation duration” hides the optimization target.
4. **Keep the selected model warm within a bounded policy.** Piper already does
   this at the native runtime layer. The improvement is to make lifecycle and
   memory-pressure behavior explicit when more engines arrive, not to recreate
   the engine more often.
5. **Avoid speculative concurrency on weak phones.** VoiceStudio mobile's own
   lease records real memory crashes from concurrent native jobs. The existing
   EpubToMp3 benchmark found some throughput benefit from two local clients on a
   Mac, but that is not evidence for safe phone concurrency.

## Model and voice assessment

### Piper Faber PT-BR

**Recommendation: keep as the primary default.** It is the strongest measured
offline PT-BR candidate for speed and memory in the current evidence. The model
does not provide VoiceStudio-style cloning or a large speaker catalogue, so the
trade-off is voice variety. A change should be driven by a quality/voice goal,
not an unsupported speed claim.

Piper Edresson was slightly faster in the phone benchmark, but it emitted 75
skipped nasal-phoneme warnings. It should not replace Faber until pronunciation
is tested and the warning is understood.

### PocketTTS Portuguese

VoiceStudio offers PocketTTS through a long-lived crash-isolated Python sidecar,
with six languages, cloning and a 6-layer fast default; the weights are gated
and require in-app acceptance
([pockettts.md lines 19–42](https://github.com/debpalash/VoiceStudio/blob/219e5072f6ea3b4a219c59372cb443892b3296b2/docs/engines/pockettts.md#L19-L42),
[lines 54–73](https://github.com/debpalash/VoiceStudio/blob/219e5072f6ea3b4a219c59372cb443892b3296b2/docs/engines/pockettts.md#L54-L73)).

**Recommendation: experimental voice/cloning option, not a speed replacement.**
The local native experiment is more relevant than VoiceStudio's sidecar and was
about 3x slower than Faber for the measured paragraph while using about 1.19 GiB
RSS. It may still be valuable if its voice cloning or perceived quality wins a
listening test. Parameter count alone did not predict its phone memory use.

### Supertonic 3

VoiceStudio documents seven preset voices, 31 supported languages including
Portuguese, CPU-only inference and OpenRAIL-M weights requiring review
([supertonic3.md lines 1–67](https://github.com/debpalash/VoiceStudio/blob/219e5072f6ea3b4a219c59372cb443892b3296b2/docs/engines/supertonic3.md#L1-L67)).

**Recommendation: optional diversity/quality experiment, not a speed project.**
It was much slower than Faber in the measured iPhone CPU configuration. Seven
presets could improve choice if Portuguese quality is good, but that has not
been listening-tested here.

### Kokoro multilingual INT8

VoiceStudio mobile's selected bundle is about 177.2 MB, declares 103 speakers,
3 GB minimum RAM and only `en`/`zh` in its own model contract
([models.json lines 124–360](https://github.com/debpalash/VoiceStudio/blob/219e5072f6ea3b4a219c59372cb443892b3296b2/mobile/contract/models.json#L124-L360)).
That catalogue entry therefore does not establish PT-BR support for its exact
artifact/front end.

EpubToMp3 separately tested a different multilingual Kokoro v1.0 configuration
that accepted `pt-br` and Dora `sid=42`; successful waveform generation did not
prove pronunciation quality, and it was the slowest of the four local PT
candidates in the phone campaign.

**Recommendation: do not adopt for speed.** Evaluate only as a non-default voice
option after exact-artifact, Portuguese listening and licence acceptance checks.
Do not transfer VoiceStudio's “103 speakers” count to the already tested Kokoro
artifact without verifying their identities match.

### Kitten

VoiceStudio mobile describes a 166,885,231-byte FP16 package, 2 GB minimum RAM,
eight speaker IDs and English only
([models.json lines 5–121](https://github.com/debpalash/VoiceStudio/blob/219e5072f6ea3b4a219c59372cb443892b3296b2/mobile/contract/models.json#L5-L121)).
The EpubToMp3 Mac campaign tested a different Kitten Nano INT8 configuration and
found it materially slower than Piper Lessac for English paragraphs.

**Recommendation: reject for the principal PT-BR goal.** The VoiceStudio entry
does not support Portuguese. It could only be reconsidered for English voice
variety with a matching-artifact benchmark.

### OmniVoice GGUF Q4_K_M

The VoiceStudio mobile contract's Q4_K_M package is 659,959,328 bytes, declares a
6 GB RAM floor and lists `pt` among eleven language tags
([models.json lines 601–668](https://github.com/debpalash/VoiceStudio/blob/219e5072f6ea3b4a219c59372cb443892b3296b2/mobile/contract/models.json#L601-L668)).
It provides cloning rather than a set of named PT-BR preset voices. Its terms are
recorded as `CC-BY-NC-4.0; Higgs Audio 2; Meta Llama 3` and non-commercial in the
contract. VoiceStudio's GGUF desktop guide calls Q4_K_M the minimal-footprint
option and estimates roughly 659 MB VRAM use
([omnivoice-gguf.md lines 17–30](https://github.com/debpalash/VoiceStudio/blob/219e5072f6ea3b4a219c59372cb443892b3296b2/docs/engines/omnivoice-gguf.md#L17-L30)).

**Recommendation: do not use as the default and do not represent it as
commercially interchangeable with Piper.** It is potentially interesting only
as an explicit experimental cloning/design feature, after the user accepts the
licence, download and memory cost. iOS 15.5 compatibility, SE memory behavior,
PT-BR quality and speed are all unverified. The current iOS shim recreating its
model per call is also a likely architectural cost, not a pattern to copy.

### MLX-Audio and audio.cpp/Breeze

MLX-Audio is useful to VoiceStudio's Apple-Silicon desktop ecosystem, but it is
not a portable native iOS 15 runtime and excludes Intel Mac. audio.cpp/Breeze is
a large research/non-commercial path focused on English/Chinese in the inspected
materials. Neither addresses the principal PT-BR speed goal.

### “600+ languages” versus usable mobile voices

VoiceStudio's broad language headlines refer chiefly to OmniVoice family
coverage. They must not be interpreted as hundreds of audited mobile voice
presets. The inspected mobile catalogue has much narrower per-artifact language
lists, and most entries expose speaker IDs rather than named, language-validated
voices. EpubToMp3 should display only voices and languages verified for the exact
download revision and front end.

## Catalogue design worth reproducing

`crates/converter-core/src/model_catalog.rs` currently provides a much smaller
catalogue abstraction than VoiceStudio's mobile contract. A Rust-owned schema
could add, without changing the default model:

- stable model ID and human name;
- provider/runtime and exact runtime revision;
- model repository plus immutable artifact revision;
- every file path, role, byte count and SHA-256;
- minimum OS and supported architectures;
- minimum/recommended RAM and expected resident memory;
- languages, regional tags, speaker count, speaker IDs and display names;
- sample rate, threading/provider limits and model-specific options;
- capability (`preset-tts`, clone, design), not a generic “TTS” bucket;
- licence ID/category, source/evidence URL, terms fingerprint, acceptance state,
  redistribution/commercial-output fields;
- download size and estimated installed size, kept distinct;
- measured speed class and language-quality status for each tested
  model/runtime/device/language combination, including the evidence date;
- installed/verified/active status kept separate from catalogue metadata.

VoiceStudio pins Sherpa-ONNX 1.13.8, `omnivoice.cpp` and `llama.cpp`, including
commits and download hashes
([pins.json lines 4–20](https://github.com/debpalash/VoiceStudio/blob/219e5072f6ea3b4a219c59372cb443892b3296b2/mobile/native/pins.json#L4-L20)).
EpubToMp3 already uses Sherpa-ONNX 1.13.8 in its benchmark/runtime work. A shared
version number does not make model contracts or integration code interchangeable,
but it reduces uncertainty for independently implementing compatible metadata.

### Product direction confirmed after this review

The product priority is **more ready-made voices**, not voice cloning. Users
should be allowed to browse and explicitly download any compatible model when
the device has sufficient free space. A 32 GB iPhone SE capacity is not itself
the usable model budget: the app must check current free space and account for
both the download and expanded installed footprint, with a safety reserve.

Before download and in the installed-model list, each model should show:

- download and installed sizes;
- number of ready-made voices and the selected language/locale coverage;
- speed class based on EpubToMp3 measurements, with tested device/runtime and
  date available as details;
- quality/performance status for the language the user wants to listen to;
- minimum/recommended RAM or unsupported-device state;
- offline/online behavior, licence restrictions and whether explicit acceptance
  is required; and
- installed, verified, update-available and active states.

Labels must distinguish measured evidence from missing evidence. For example,
`Fast on iPhone 16e · PT-BR measured` and `PT-BR not evaluated` are valid;
`Fast` or `Good Portuguese` without a pinned artifact and reproducible test are
not. Language quality cannot be inferred merely because synthesis completes or
the model lists a generic `pt` tag.

## Segment cache design

The cache identity must be more complete than `text + voice`. At minimum it
should include:

```text
schema_version
normalized_text_bytes
normalization_version
provider + runtime_revision
model_id + artifact_revision + model_hash
voice_id/speaker_id + language
speed + synthesis/model options
output sample_rate/channels/format
```

Pause/silence segments can be deterministic synthetic artifacts. Cached outputs
should be written atomically, validated before publication, bounded by an
eviction policy and protected from cross-model collisions. Chapter MP3s remain
derived artifacts assembled from ordered segment outputs; they should not become
the only reusable cache layer.

VoiceStudio's implementation is evidence that this design is practical, but its
exact Swift code and cache key must not be copied. Its own key is useful as a
conceptual lower bound, not automatically sufficient for EpubToMp3's provider,
normalizer and artifact identities.

## Licensing and compatibility constraints

VoiceStudio states that its application is AGPL-3.0-only and that bundled or
downloaded models retain separate licences
([LICENSE-NOTICE.md lines 9–28](https://github.com/debpalash/VoiceStudio/blob/219e5072f6ea3b4a219c59372cb443892b3296b2/LICENSE-NOTICE.md#L9-L28),
[lines 47–80](https://github.com/debpalash/VoiceStudio/blob/219e5072f6ea3b4a219c59372cb443892b3296b2/LICENSE-NOTICE.md#L47-L80)).
EpubToMp3's Rust workspace declares MIT in `Cargo.toml`.

Consequences:

- ideas, algorithms and observed behavior may be independently implemented;
- source copying, close translation or inclusion of VoiceStudio files requires a
  deliberate AGPL compatibility/distribution decision;
- model code licence, model-weight licence, phonemizer/data licence and output
  rights must be tracked separately;
- “open source” does not imply commercial model-output permission;
- a catalogue must bind accepted terms to a terms fingerprint/revision so changed
  terms cannot silently inherit old consent.

This is technical due diligence, not legal advice.

## Prioritized roadmap

### P0 — no model change

1. Define a Rust model/voice manifest with immutable revisions, hashes, language,
   speaker, RAM/OS and licence fields.
2. Add a benchmark/telemetry vocabulary for cold load, warm synthesis, time to
   first PCM, first non-silent PCM, first persisted playable chunk, full output,
   RTF and peak RSS.
3. Benchmark the current integrated Piper path at 800/2,000/5,000-character
   boundaries, including validation/staging cost, before changing its runtime or
   concurrency.
4. Preserve Piper Faber as the default and installed system TTS as fallback.

### P1 — likely product-level speed improvement

1. Introduce a validated persistent per-segment cache under the existing job and
   chapter orchestration.
2. Schedule the current reading position first and prefetch nearby/next content
   within the existing single-heavy-job constraints.
3. Measure cold and warm end-to-end behavior in the real app, including cache hit,
   miss, cancellation and corruption recovery.
4. Expose additional Piper voices only when the exact artifact has validated
   speaker/language metadata; do not invent voice labels from raw numeric IDs.

### P2 — ready-made voice expansion, not cloning

Audit additional Piper PT-BR artifacts first, then run a controlled Supertonic
experiment for its seven ready-made voices. Require identical text, exact model
hashes, three or more repetitions after separately recorded cold load, output
validation, blind PT-BR listening, peak RSS, thermal/battery observation and
iPhone SE/iOS 15.5 acceptance. Pocket is no longer a priority because its main
differentiator is cloning and its measured process RSS was roughly 1.19 GiB.

### P3 — high-cost experimental cloning

Consider OmniVoice GGUF only behind explicit opt-in after licensing review. The
experiment must first prove it can build and run on iOS 15.5, remain within the
SE memory envelope, preserve cancellation and keep a safe resident lifecycle.
No current evidence supports making it a default.

## Proposed acceptance experiment

Before any provider/default decision, compare the current Piper baseline with
one candidate at a time:

1. Pin runtime and model artifacts by commit/SHA-256.
2. Use the same short sentence, 655-character paragraph and representative
   chapter blocks in PT-BR.
3. Record cold model load separately from at least five warm syntheses.
4. Measure first callback, first non-silent PCM, first player-ready segment, full
   segment and final export.
5. Validate duration, decoding, finite/non-silent samples and exact text coverage.
6. Test cancellation during load and generation, repeated sessions, cache hit,
   corrupted cache and model/voice identity changes.
7. Record peak RSS, memory warning behavior, temperature and battery for sustained
   work.
8. Perform blinded listening focused on pronunciation, prosody, long-sentence
   stability and PT-BR naturalness.
9. Run on the required iPhone SE (1st generation)/iOS 15.5 target; a newer phone
   does not establish acceptance.

Only then should “faster”, “better” or “supported” be used in product copy.

## Known gaps and unanswered questions

- There is no VoiceStudio result table proving mobile RTF/TTFA for the inspected
  Kitten, Kokoro or OmniVoice packages.
- VoiceStudio's iOS minimum is 17; none of its mobile native paths was verified on
  iOS 15.5.
- The required iPhone SE acceptance run has not been performed for Piper,
  Pocket, Supertonic, Kokoro or OmniVoice in this review.
- No candidate has a controlled blind PT-BR listening score in the retained
  evidence.
- Ready-made voice variety is the confirmed priority; cloning is not. This moves
  Pocket and OmniVoice out of the active roadmap unless that goal changes.
- Users may download any compatible model if sufficient storage is available.
  The precise free-space safety reserve and acceptable peak RSS for the weakest
  supported device still need an implementation policy and device validation.
- Cache hit rate and the frequency of partial chapter edits are not measured, so
  the segment-cache gain remains a well-founded hypothesis rather than a
  quantified product result.
- The exact set of additional Piper PT-BR artifacts that meet quality and licence
  requirements has not been audited here.

## Final recommendation

Keep Piper Faber as the primary PT-BR model. Do not import a VoiceStudio engine
for “speed” on the present evidence. First reproduce the parts VoiceStudio gets
right operationally—a complete model/licence catalogue, segment reuse, explicit
model residence and truthful cold/warm/first-playable metrics—inside the existing
Rust architecture. Then evaluate one optional model at a time for a specific
unmet goal: Pocket for cloning, Supertonic for preset diversity, or OmniVoice for
high-cost experimental cloning. None is currently justified as a faster default.
