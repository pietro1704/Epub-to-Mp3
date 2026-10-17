# Physical iPhone lightweight TTS benchmark

Date: 2026-10-14. Device: physical iPhone 16e, iOS 27.0.1 (24A446). Five offline checkpoints plus the current production Rust Edge client were exercised. Five offline candidates completed all six synthesis/decode checks; Edge completed five and hit the configured 45-second deadline on its final attempt. This is a performance/feasibility experiment, not a blind quality ranking or an end-to-end app conversion benchmark.

## Measured comparison

All candidates received the identical synthetic Portuguese fixtures: 116-character short passage and 655-character paragraph, three attempts each. The table uses median file-ready time and process peak resident memory. Lower RTF (generation time divided by output audio duration) is faster. Voices and speaking durations differ.

| Candidate / exact configuration | Paragraph file ready | Paragraph RTF | Process peak RSS | Staged model assets | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| Piper Edresson low, FP32, 2 CPU threads | 2.15 s | 0.046 | 327 MiB | 77.3 MiB | 6/6; nasal phoneme warning |
| Piper Faber medium, FP32, 2 CPU threads | 2.43 s | 0.065 | 343 MiB | 77.4 MiB | 6/6 |
| Pocket Portuguese 6-layer, mixed int8/FP32, 2 total threads | 7.29 s | 0.220 | 1,190 MiB | 193.5 MiB staged; 158.0 MiB required | 6/6 |
| Supertonic 3 int8, 8 steps, sid=0, `lang=pt`, 2 CPU threads | 19.08 s | 0.346 | 585 MiB | 138.6 MiB | 6/6 |
| Kokoro v1.0 multilingual int8, Dora sid=42, `lang=pt-br`, 2 CPU threads | 33.68 s | 0.852 | 523 MiB | 181.1 MiB | 6/6 |
| Edge `pt-BR-FranciscaNeural`, production Rust reference client | 1.72–14.37 s for two successful paragraphs; final attempt timed out | 0.040–0.330 for successful paragraphs | 92.8 MiB, excluding cloud inference | No local weights | 5/6; incomplete baseline |

Edge short-passage attempts took 14.29 s, 1.35 s and 14.33 s. Do not rank it using only its fastest result. Its last paragraph reached the **benchmark's** 45-second synthesis deadline; this does not establish that production's longer retry policy would never complete. The initial legacy Swift bridge also failed before generating audio; its failure report is preserved separately and excluded from the Rust comparison.

Piper Faber is the strongest next offline evaluation candidate based on this run's speed and memory. Edresson was faster but logged 75 instances of skipped nasal phoneme U+0303; pronunciation needs investigation before selection. Pocket streamed quickly but used about 1.16 GiB of process memory, making its parameter count an unreliable proxy for suitability on weak phones. Supertonic and Kokoro were slower in these specific CPU configurations. This does not rank CoreML/Metal variants or establish performance on iPhone SE.

## Startup and callback observations

Model load took Edresson 0.421 s, Faber 0.459 s, Kokoro 0.450 s, Supertonic 0.334 s and Pocket 0.254 s. These exclude executable/UI launch and do not imply a cold OS page cache.

Median short-fixture file-ready times were Edresson 0.413 s, Faber 0.448 s, Kokoro 6.182 s, Supertonic 3.806 s and Pocket 1.585 s. For first generation after model load, Pocket's first PCM callback arrived at 0.819 s; warm callbacks were much earlier. Callback time is **not** time to first audible speech: Pocket prepends 250 ms of silence inside its first callback, and no speaker playback timing was measured. Edge first-frame/PCM latency was not measured.

## Native setup and exact variants

- Local synthesis used sherpa-onnx 1.13.8 and ONNX Runtime 1.28.2 iOS shared frameworks, whose archive checksums matched their package manifests. The optimized Swift harness was compiled with Xcode 16.4/iOS 18.5 SDK, targeting iOS 15.0 minimum. Pocket's arm64 object was independently checked as platform IOS, minimum 15.0. Builds and device runs held the existing exclusive `/tmp/epub2mp3.heavy-job.lock`.
- A separate test app reused the existing `com.pietrocode.epubtomp3.uitests` provisioning identity because this Mac had no account to create a new app profile. Its Documents container owned all model copies and results. The production app was stopped during benchmarking; no production provider configuration or imported-book directory was changed.
- Kokoro was refined from the initial v1.1 candidate to `kokoro-int8-multi-lang-v1_0` to use the documented 53-speaker map: Brazilian Dora is sid 42. Native creation and synthesis accepted `pt-br`. Successful waveform generation does not prove pronunciation quality. [Official speaker map](https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/kokoro.html).
- Pocket used KevinAHM's six-layer Portuguese ONNX bundle at revision `58a6d00cf13d239b6748cb0769f35c580a8f606c`, consumed by `PocketTTS.cpp-multilingual` revision `3ed176a2b238b7ddb62b4aea4e7469ae4bcc3489`. SentencePiece 0.2.1 and the existing iOS ORT framework were compiled/linked through the C FFI. A synthetic Edge fixture from the previous host experiment supplied voice conditioning; no recorded person's voice was used. Two downloaded int8 auxiliary graphs were not used by this adapter, explaining staged versus required bytes. The C++ decoder and autoregressive generator split the two-thread budget. [Export](https://huggingface.co/KevinAHM/pocket-tts-onnx), [native implementation](https://github.com/netai369/PocketTTS.cpp-multilingual).
- Edge's second run used the actual `converter_core::tts::synthesize_with_reference_client` through a benchmark-only C entrypoint. Every attempt opened a new synthesis request; no local audio cache was reused. Cloud-side cache behavior, network transport and inference time were not separable.

## Verification and evidence

Thirty-five outputs passed native AVAudioFile full decoding, positive duration, finite samples and a non-silent peak threshold. Source parsing alone was not used as runtime evidence. Three trials do not support a reliable p95. No blind listening/MOS, ASR word-error rate, battery, temperature, English, long-book or production-player test was performed. There was no audible playback. Peak RSS includes validation and framework memory; the final Pocket/Edge test binary additionally linked their native adapters. Fixed order and network variation limit causal comparisons.

The compact [measured JSON](tts-phone-benchmark-2026-10-14.json) preserves results and limitations. Detailed local evidence is under `.reports/tts-six/20261014/`: per-candidate `report.json` and generated WAV/MP3 files, `model-inventory.json` with asset sizes/hashes, `download-manifest.json`, `pocket-provenance.json`, build/launch/transfer logs, and second-batch `host-phases-*.json`. Native synthesis/validation intervals are inside native benchmark wall time; do not add them to that wall time. The initial batch did not record separate host phase intervals.

Executed project tasks: `ios:device:preflight`, `tts:phone:build-pocket`, `tts:phone:build-edge`, `tts:phone:benchmark`, `tts:phone:summary`, and `preflight`. Repository preflight passed its local branch/whitespace gates; Python/lint checks were deferred to CI by that task. No CI/PR monitoring was performed.

The reproduction harness is retained in [tts-phone-benchmark](tts-phone-benchmark/). `tts:phone:cleanup` removed 4,339 files totaling 2,414,730,303 bytes (2.25 GiB) from the isolated download/build tree and verified its absence. Pre-existing repository models and generated evidence are preserved. Device cleanup is established by the successful test-app uninstall receipt. Host removal evidence is recorded in `host-cleanup.json`; temporary downloaded metadata was also deleted. The production app was reopened and its active process confirmed after cleanup; no Simulator remained booted.
