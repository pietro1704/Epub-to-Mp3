# Speed-first TTS fallback investigation

> **Research status (reviewed 2026-10-21).** The Edge-primary/Piper-suspended decision and experiment authorization are historical task scope. Use [current runtime/provider policy](../../AGENTS.md) for present defaults and [execution policy](../agents/execution-policy.md) for any newly requested experiment.

Date: 2026-10-13. Task: APP-20261013-03.

User correction: candidates must be free of paid SDK/API requirements. The
commercial alternatives described below are inventory context and are excluded
from the recommended shortlist. Recommended direction: keep Edge primary and
evaluate installed offline platform TTS before adding another bundled model.
No fallback implementation or automatic provider switch is authorized by this
decision discussion.

## Historical decision and scope

Keep **Edge active**. Do not enable or exercise Piper in the app for this task.
The earlier Piper-native-playback gate is deferred by the user's correction.
Researching Piper as a candidate does not select it as a fallback. Existing
production defaults are already Edge; no production code or saved preferences
were changed in this research slice.

Priority: time to usable speech and continuous playback on weak phones, then
resource consumption and intelligibility. Portuguese is the primary comparison
language inferred from current app configuration; other-language coverage is
recorded rather than treated as interchangeable.

This investigation covers the practical families and providers in the companion
inventories. It cannot benchmark literally every public/private checkpoint.
Only installed executable paths were measured locally; missing runtimes, model
assets and mobile hardware are explicit gaps, not benchmark results.

Plan used: inspect existing defaults/artifacts and prior evidence; parallel
primary-source research for compact models and platform/cloud engines; run a
bounded serial same-text host experiment; audit output and comparison limits;
publish the recommendation and retained evidence. No app/runtime integration,
new model downloads, physical-device interaction, or automatic fallback change.

## Recommendation

Piper is **not established as the best universal fallback**. It is one of the
best-supported compact neural CPU candidates, with materially better published
weak-ARM throughput than the examined Kokoro checkpoint. That is narrower than
a pt-BR weak-phone verdict.

For an offline fallback, benchmark installed platform voices first: Apple's
`AVSpeechSynthesizer` and Android `TextToSpeech`. They avoid adding a new bundled
model/runtime, although a usable offline voice may require an OS download and
is not guaranteed on every device. API synthesis/export capability is documented
by [Apple](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write%28_%3Atobuffercallback%3A%29)
and [Android](https://developer.android.com/reference/android/speech/tts/TextToSpeech).
This is an engineering recommendation, not a mobile speed victory.

If the product requires an app-owned portable offline engine, compare eSpeak NG
and RHVoice with compact neural candidates; they offer Portuguese and smaller
deployment approaches, with voice quality and licensing tradeoffs. Keep Piper
as a research baseline. Supertonic 3 and Pocket Portuguese merit timing, while
Kokoro is a quality candidate whose backend choice strongly affects speed.
English-only compact models cannot be promoted as pt-BR fallbacks.

Commercial embedded SDKs are also relevant: Orca, ReadSpeaker, Acapela and
CereProc. [Picovoice's benchmark](https://github.com/Picovoice/text-to-speech-benchmark)
reports a 7 MB Orca model, 41 MB peak RAM and 106 ms first-token-to-speech; these
are vendor desktop/LLM-workload results, not pt-BR phone measurements. They make
Orca a serious footprint candidate if its licensing and integration are
acceptable, without proving that it is faster than Piper on weak phones.

A second cloud service covers Edge provider failure, but not lost connectivity.
Azure, Google, Polly, ElevenLabs and Cartesia are meaningful online candidates.
Their advertised server/model latencies do not establish phone request-to-audio
latency; no paid API benchmark ran and no provider key was inspected.

## Executed same-text host benchmark

Command: `mise exec -- ruby docs/research/tts-host-benchmark.rb`.

Hardware: Intel Core i5-8259U 2.30 GHz, x86_64, 8 GiB RAM, macOS. Twelve runs:
two pt-BR inputs × two engines × three repetitions. Engines alternate serially
under the project's shared `/tmp/epub2mp3.heavy-job.lock`. Existing Debug Rust
`embedded_edge_probe` was reused; no build/model installation occurred.

Apple uses installed Luciana through `say`, followed by MP3 encoding; Edge uses
`pt-BR-FranciscaNeural` through the existing Rust reference-client probe. All
outputs are mono 24 kHz MP3; Apple encoding targets 48 kbit/s. Every artifact has
positive duration and passed full independent `ffmpeg` decoding. Validation is
outside the synthesis/encoding timing. Text, binary/output hashes, raw timings,
commands and metadata are retained in the [JSON snapshot](tts-host-benchmark-2026-10-13.json).

| Input | Engine | Median artifact-ready time | Range, 3 runs | Generated speech | Median RTF |
| --- | --- | ---: | ---: | ---: | ---: |
| Short | Apple Luciana | 0.791 s | 0.789–2.059 s | 9.196 s | 0.0860 |
| Short | Edge Francisca | 1.905 s | 1.083–1.980 s | 9.312 s | 0.2046 |
| Paragraph | Apple Luciana | 1.355 s | 1.352–1.362 s | 48.771 s | 0.0278 |
| Paragraph | Edge Francisca | 2.267 s | 1.294–3.236 s | 43.536 s | 0.0521 |

RTF here is synthesis plus encoding wall time divided by generated audio
duration; smaller is faster. Apple had the lower median on both inputs, but
Edge's fastest paragraph trial beat Apple's fastest. These results support
investigating system TTS, not replacing the user-selected Edge default.

Important bounds: three fresh processes per cell are not three fully cold model
loads. System voice services may stay warm, and the first Apple short trial was
slower. Speaking rates/voices differ, so character throughput and wall time must
accompany RTF. The child-process RSS was about 40–42 MiB for `say` and 11–12 MiB
for Edge; **these are not comparable total engine footprints**, because Apple
speech service memory and cloud inference are outside the child. TTFA, audible
output, battery, thermal behavior, p95, native-app delivery and mobile speed were
not measured. Audio was freshly generated by this harness; upstream cache state
is unknown. Raw files/logs remain in `.reports/tts-host/20261013T200903Z/`.

The fixed Apple-then-Edge order and 10 ms process-exit polling are additional
experimental limits. `say` is not direct iOS `AVSpeechSynthesizer` evidence.
Apple MP3 encoding memory is outside the reported `say` RSS. Successful decoding
and a non-silent signal do not establish complete spoken-text fidelity; no ASR
transcription or human pronunciation/quality study ran.

## Published evidence most relevant to weak hardware

[Sherpa's Raspberry Pi 4 table](https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/rtf.html)
provides a useful same-runtime comparison in English. Four-thread RTF: Piper
lessac-medium **0.357**, Matcha LJS **0.411**, Kokoro 0.19 **2.774**. One-thread
values are **0.774**, **0.941**, **6.629** respectively. This favors the examined
Piper checkpoint on modest ARM CPU; it does not measure current quantized
Kokoro, Brazilian Portuguese or a phone.

[Soniqo's physical Android implementation](https://soniqo.audio/benchmarks)
reports Supertonic 3/LiteRT **0.34 RTF**, **~1.1 s TTFA**, **832 MB RSS**, and
Kokoro/ONNX FP32 **0.53 RTF**, **640 MB RSS**. This is flagship-class hardware,
and the reported Galaxy S23 / `SM-S918B` naming is inconsistent. Memory is a
material reason not to adopt either as a weak-phone default from this table.

Éist publishes mobile observations, but its
[RTF methodology](https://eist.app/research/on-device-tts-benchmarks) contradicts
the introductory metric definition. Its uncontrolled cohorts also differ in
models, devices and runtimes. Do not use those numbers as a definitive ranking
without resolving the metric and comparison protocol.

The existing repository's physical Edge benchmark on **iPhone 16e**, run
`699FF2AE-0A79-406A-889C-FEF3EF01110F`, passed one native test. LOTR chapters 8–9:
432.123 s synthesis / 7,019.568 s audio, RTF 0.0616; Christie 6–7: 6.353 s /
349.248 s, RTF 0.0182. First completed-chapter callbacks were 206.256 s and
3.197 s; these are neither first chunk nor acoustic latency. This is prior
high-end-phone/network evidence, not a new run or a fair cross-model comparison.
Source: `.reports/device/699FF2AE-0A79-406A-889C-FEF3EF01110F/report.json`.

## Inventory and evidence gaps

Detailed sources, licenses, languages and model-specific qualifications:

- [Compact and heavier local models](2026-10-13-compact-tts-models.md): Piper,
  Supertonic, Pocket, Kokoro, Kitten legacy/2, Inflect, MMS, Matcha/VITS and other
  current neural families.
- [Platform, traditional and cloud engines](2026-10-13-platform-cloud-tts.md):
  Apple, Android, eSpeak NG, RHVoice, Flite and cloud alternatives.

The October 2 selection note predates current Portuguese coverage and the
speed-first correction. Its suggested Kokoro-first quality policy is not the
decision for this task.

Piper's installed CLI uses Python, deferred to CI by project policy. Other
neural models lack a locally usable tested native inference package. No local
Piper/Kokoro/Pocket/Supertonic/Kitten/Inflect synthesis occurred in this task.
No low-end physical Android target is available to this session; iOS Simulator
timings cannot stand in for physical phone speed. Published numbers fill context
only; **the requested broad physical-mobile benchmark remains incomplete**.

## Acceptance for the next benchmark slice

Use at least one physical low-end Android and an older compatible iPhone, with
explicit task authorization before device actions. Start with installed offline
pt-BR system voices, then the shortlisted licensed packages that can actually
run there. Record exact chip/RAM/OS, engine version/checkpoint/hash, CPU threads,
text and output format. Separate model load, first non-silent PCM, first playable
encoded segment and complete artifact. Measure warm/cold p50/p95 with sufficient
trials, sustained RTF, peak total memory, stalls, cancellation, battery and
thermal degradation. Test offline mode and pronunciation of dates/numbers.

Do not make playback wait for an entire chapter when evaluating latency. Keep
one process/model at a time and preserve imported books/audio. Candidate
acceptance thresholds are product decisions, not demonstrated results: for
example p95 first playable speech <=1 s and sustained RTF <=0.5 would provide
buffer margin, but must be validated against weak target hardware. A shared
Rust-owned provider boundary must retain artifact/progress/cancellation ownership
if native platform adapters are later implemented.

## Verification and delivery bounds

The benchmark exited 0 with 12/12 fully decoded outputs. Ruby syntax validation
passed; JSON read-back asserted all twelve successful records; final scoped
whitespace audit passed. No native app build, Simulator interaction, device test,
CI/PR monitoring, production engine change, or commit/push was performed in this
research slice. Findings are available locally; physical mobile acceptance
remains open.
