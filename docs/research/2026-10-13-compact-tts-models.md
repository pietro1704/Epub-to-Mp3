# Compact TTS candidates for weak devices

> **Research status (reviewed 2026-10-21).** The Edge-primary premise is the October 13 task policy, superseded by [current runtime/provider policy](../../AGENTS.md). Preserve candidate/source comparisons as dated research; model installation requires an explicit user action.

Research date: 2026-10-13. Scope: primary-source inventory and published measurements; no model downloads, synthesis, or device benchmarks were performed for this note. Edge remains the current requested engine. Parameter count, disk size, peak memory, first-audio latency and sustained throughput are different metrics.

## Decision supported by current evidence

Piper is a credible **neural offline baseline**, not a proven universal fastest fallback. Benchmark order for Portuguese should include system TTS / eSpeak separately, Piper `pt_BR-edresson-low` and `pt_BR-faber-medium`, Supertonic 3, and Pocket Portuguese. Kokoro belongs in a quality-oriented comparison. Inflect and Kitten legacy are useful English controls, not established Portuguese substitutes. This is an experimental priority order, not a measured ranking in this application.

No checked source supplies a controlled pt-BR comparison on the application's oldest supported physical phone, including cold start, first playable audio, memory, power and sustained thermal behavior. Desktop, server and Simulator numbers cannot establish that acceptance.

## Comparable weak ARM measurements

Sherpa publishes C++ `sherpa-onnx-offline-tts` measurements on **Raspberry Pi 4 Model B Rev 1.5**, using the same English passage. These are generation/audio-duration RTF values (smaller is faster), not TTFA. Runtime version, repeated-run distribution and thermal settings are not given beside the tables.

| Exact checkpoint/path | 1 thread | 2 threads | 3 threads | 4 threads |
| --- | ---: | ---: | ---: | ---: |
| Piper `en_US-lessac-medium` | 0.774 | 0.482 | 0.390 | 0.357 |
| Matcha `matcha-icefall-en_US-ljspeech`, 3 steps + Vocos | 0.941 | 0.561 | 0.451 | 0.411 |
| Kokoro `kokoro-en-v0_19`, speaker 2 | 6.629 | 3.870 | 2.999 | 2.774 |

Sources: [Piper benchmark](https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/vits.html#en-us-lessac-medium-english-single-speaker), [Matcha benchmark](https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/matcha.html), [Kokoro benchmark](https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/kokoro.html).

Piper beats those specific checkpoints on that ARM board. Kokoro 0.19 is an older English model; these results do not rank Kokoro 1.0 quantized/CoreML against Piper pt-BR on phones. All three improve with more threads here; a mobile implementation must measure scheduling, UI contention and battery separately.

## Physical mobile evidence and its limits

[Soniqo's own implementation benchmark](https://soniqo.audio/benchmarks) reports ARM64 CPU results on a device labeled Galaxy S23, identifier `SM-S918B` (the label/identifier pairing should be clarified). Supertonic 3 through LiteRT: RTF **0.34**, TTFA **~1.1 s**, peak RSS **832 MB**. Kokoro 82M through ONNX FP32: RTF **0.53**, RSS **640 MB**. No Piper row, Portuguese fixture, trial distribution, thread count or thermal protocol accompanies these phone rows. This is flagship-class evidence, not evidence for weak phones, and compares different runtimes.

[Éist's production snapshot](https://eist.app/research/on-device-tts-benchmarks), 25 August–15 September 2026, reports median values for Piper Android/iOS **0.247/0.115**, Supertonic **0.791/0.304**, Kokoro **3.48/1.325**, and iOS Kokoro Turbo **0.438**. Piper/Kokoro use sherpa-onnx 1.12.40; Supertonic is v3; Turbo uses MLX/Metal bf16. These are uncontrolled usage cohorts, not paired engine runs. The page contradicts itself: introduction defines smaller as faster, but methodology describes audio time divided by synthesis time. Therefore these numbers must remain **published metric values with an unresolved definition**, not trusted speed rankings. Android models did not clear cohort thresholds; system TTS, memory, thermals and battery are excluded.

## Compact inventory

| Candidate | Language and footprint | Deployment/license facts | Speed evidence / disposition |
| --- | --- | --- | --- |
| Piper low/medium | Native pt-BR voices. Edresson low ONNX **63.1 MB**; Faber medium **63.2 MB**. | Current Piper engine GPL-3.0; each voice's own model card controls its weights. ONNX VITS plus phonemization. | Strong weak-ARM baseline above, but no checked pt-BR phone result. Low does not imply smaller download. |
| Supertonic 2 / 3 | v2: 5 languages; v3: 31 including Portuguese, **99M** parameters, 44.1 kHz. | ONNX; Swift/iOS/Rust examples. MIT sample code, **OpenRAIL-M weights**. Upstream archived; development/support ended. | Actual phone result above. Worth timing despite archive risk. Portuguese support does not establish Brazilian accent quality. |
| Pocket TTS | Current README supports English, French, German, **Portuguese**, Italian, Spanish, Dutch; **100M** headline. Larger non-English 24-layer variants also exist. | Streaming; MIT code; check voice licenses individually. Current sherpa API includes Pocket. | Author claims **~200 ms** first chunk and **~6x realtime** on MacBook Air M4 CPU, 2 cores; implied RTF ~0.167. Not a weak-phone or Portuguese benchmark. |
| Kokoro 82M v1.0 | Brazilian Portuguese `pf_dora`, `pm_alex`, `pm_santa`; `lang_code='p'`, eSpeak `pt-br`. | Apache-2.0 weights; ONNX/CoreML alternatives exist. | Phone/runtime outcome depends heavily on implementation; older Pi4 result cannot settle current deployment. |
| Kitten legacy 0.8 | Nano **15M**, FP32 **56 MB** / int8 **25 MB**; Micro **40M/41 MB**; Mini **80M/80 MB**. Established lightweight English path. | ONNX CPU, eight voices; Swift SDK exists. Code Apache-2.0; inspect checkpoint license. | No controlled phone RTF found in checked primary sources. Small size alone does not prove fastest inference. |
| Inflect v2 | Fixed English male; Nano **3.97M/15.97 MB FP32**; Micro **9.36M/37.53 MB FP32**; integrated waveform decoder. | Apache-2.0 code/weights; native GGML community ports exist. | Author benchmark: HF CPU Upgrade **8 vCPU/32 GB**, 4 threads, 100 prompts × 3 passes: **10.72x / 6.28x realtime** Nano/Micro. Not mobile or Portuguese. |
| MMS Portuguese | `facebook/mms-tts-por`, VITS, **36.3M**. | **CC-BY-NC-4.0** weights; separate checkpoint per language; sherpa export path. | No paired pt-BR phone benchmark found. Noncommercial license affects product eligibility. |
| Matcha / other VITS | Checkpoint-specific language; examined Matcha is English, not Portuguese. | Matcha requires acoustic model **and vocoder**; sherpa is a runtime, not another TTS model. | Matcha's Pi4 result is close to but slower than examined Piper. VITS family membership does not determine speed. |

Sources: [Piper engine](https://github.com/OHF-Voice/piper1-gpl), [Edresson asset](https://huggingface.co/rhasspy/piper-voices/tree/main/pt/pt_BR/edresson/low), [Faber asset](https://huggingface.co/rhasspy/piper-voices/tree/main/pt/pt_BR/faber/medium), [Supertonic archive](https://github.com/supertone-oss-archive/supertonic), [Supertonic 3 model](https://huggingface.co/supertone-oss-archive/supertonic-3), [Pocket README](https://github.com/kyutai-labs/pocket-tts), [Kokoro voices](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md), [Kokoro model](https://huggingface.co/hexgrad/Kokoro-82M), [Kitten lightweight documentation](https://github.com/KittenML/KittenTTS/blob/main/docs/onnx-models.md), [Kitten model table](https://github.com/KittenML/KittenTTS), [Swift SDK](https://github.com/KittenML/KittenTTS-swift), [Inflect author](https://github.com/owenawsong/Inflect), [MMS Portuguese](https://huggingface.co/facebook/mms-tts-por), [sherpa families](https://k2-fsa.github.io/sherpa/onnx/c-api/html/tts.html).

## Larger/newer tiers: inventory, not weak-phone defaults

- **KittenTTS 2** differs from legacy: 1.7B, Portuguese among 20 languages, 506 MiB reduced or 947 MiB default weights; README CPU prerequisite approximately **6 GB RAM**. Chunk streaming waits for complete chunk synthesis. Its given A100 example yields first 21 seconds after 17 seconds. Code Apache-2.0, weights Stellon Labs Community License. This does not inherit legacy Nano's footprint. [Author](https://github.com/KittenML/KittenTTS).
- **Qwen3-TTS** 0.6B/1.7B supports Portuguese and streaming; Apache-2.0. Author's **97 ms** headline omits a weak-phone hardware configuration in the README, so it cannot be compared with mobile TTFA. [Author](https://github.com/QwenLM/Qwen3-TTS).
- **VoxCPM2** 2B supports 30 languages including Portuguese; Apache-2.0. Author reports RTX4090 RTF ~0.30 PyTorch/~0.13 accelerated, but **M4 Pro Metal Q8 RTF ~1.76** in native llama.cpp-omni. Older 0.5B/0.6B variants are Chinese/English only. [Author](https://github.com/OpenBMB/VoxCPM).
- **Chatterbox** current Nano 110M is English; author claims 3x realtime on 8 cores without specifying phone hardware. Multilingual V3 is 500M; Turbo 350M is English. Treat multilingual product and Nano separately. [Author](https://github.com/resemble-ai/chatterbox).
- **F5-TTS / E2-TTS** use iterative flow generation; official code MIT, pretrained weights CC-BY-NC. No checked official weak-phone pt-BR benchmark. **XTTS-v2** supports Portuguese under Coqui Public Model License; no matched weak-phone timing in its card. [F5 author](https://github.com/SWivid/F5-TTS), [XTTS card](https://huggingface.co/coqui/XTTS-v2).

## Additional relevant families

This covers relevant deployable families rather than literally every checkpoint, private model, finetune or future release. Absence below means no suitable official Portuguese release was established in the checked source, not proof that no community adaptation exists.

| Family / checked release | Portuguese eligibility | Evidence and reason to defer as first weak-phone candidate |
| --- | --- | --- |
| NeuTTS Nano / Air / 2E | Official Nano collection: English, French, German, Spanish; Air/2E English. No official PT listed. | Nano **120M active / 229M including embeddings**; Air **360M active / 552M total**. Author Q4 benchmark Galaxy **A25 5G**, CPU, 6 threads, 500-token prefill + 250-token output: Nano **45 tokens/s**, Air **20 tokens/s**. **Excludes codec**, so cannot establish full-pipeline RTF/TTFA. Air Apache-2.0; Nano/2E NeuTTS Open License 1.0. [Author](https://github.com/neuphonic/neutts). |
| Soprano 1.1 80M | Official card explicitly English-only, no cloning. | Author claims up to **20x realtime CPU**, **<250 ms** CPU latency, **<1 GB** memory; comparable phone hardware/protocol absent from overview. Apache-2.0. Useful English control, not pt-BR replacement. [Model](https://huggingface.co/ekwek/Soprano-1.1-80M), [claims](https://github.com/ekwek1/soprano). |
| OuteTTS 1.0 0.6B | Official trained-language list omits PT; untrained-language generation described as varying success. | Autoregressive LM plus DAC decoding, speaker-reference dependent; GGUF backend exists. No checked paired weak-phone PT benchmark. Cross-lingual possibility is insufficient pronunciation acceptance. [Card](https://huggingface.co/OuteAI/OuteTTS-1.0-0.6B). |
| MeloTTS | Official EN/ES/FR/ZH/JA/KO list omits PT. | CPU-oriented VITS family; no official pt-BR release established. [Author](https://github.com/myshell-ai/MeloTTS). |
| Silero TTS | Checked official model tables/registry do not list PT. | CPU-capable PyTorch checkpoints are language-specific. No matched PT phone measurements established; avoid confusing its VAD product with TTS. [Author](https://github.com/snakers4/silero-models), [registry](https://raw.githubusercontent.com/snakers4/silero-models/master/models.yml). |
| CosyVoice 3 | Official nine-language list excludes PT. | Official released 0.5B family has bi-streaming but no checked weak-phone PT checkpoint/benchmark. **150 ms** headline does not demonstrate old-phone latency. Apache-2.0 code. [Author](https://github.com/QwenAudio/CosyVoice). |
| Fish S2 Pro | PT explicitly Tier 2 in model card. | **4B slow AR + 400M fast AR**; published **H200 GPU** RTF **0.195**, TTFA **~100 ms**, not phone evidence. S2 Pro weights Fish Audio Research License; current repository has other models under Community License. [Card](https://huggingface.co/fishaudio/s2-pro), [license distinction](https://github.com/fishaudio/fish-speech). |
| OmniVoice | Official language table includes Portuguese **`pt` / `por`**. | Diffusion LM, CUDA/FlashInfer optimization benchmark on **H100**, no checked weak-phone PT measurements. Broad language count does not establish usable Brazilian pronunciation. Apache-2.0 repository. [Author](https://github.com/k2-fsa/OmniVoice), [language list](https://github.com/k2-fsa/OmniVoice/blob/master/docs/languages.md). |
| VibeVoice Realtime 0.5B | Official **experimental PT speaker** available; not equivalent to verified pt-BR quality. | Streaming, **~300 ms** headline without matched weak-phone protocol. Older 1.5B TTS runtime was removed/disabled; distinguish released Realtime from that old path and from ASR. [Author](https://github.com/microsoft/VibeVoice). |
| Magpie Multilingual v2607 | **PT added July 21, 2026**, twelve languages. Older v2602/v2512 cards differ. | Release name 357M, card describes **364M** encoder-decoder plus NanoCodec; NVIDIA Open Model License. Native NeMo-Speech.cpp/GGUF path exists, but no checked pt-BR weak-phone benchmark. Five English speaker identities can speak PT; pronunciation must be evaluated. [Official card](https://huggingface.co/nvidia/magpie_tts_multilingual_357m). |
| Parler Mini v1 | Official card marks English; no official PT checkpoint established here. | Description-conditioned autoregressive codec generation; Apache-2.0. Fine-tuning is research scope, not a ready pt-BR fallback. [Card](https://huggingface.co/parler-tts/parler-tts-mini-v1). |
| StyleTTS2 | Official provided LJSpeech/LibriTTS checkpoints are English. | General architecture can be retrained, but multilingual PL-BERT support alone does not provide Portuguese acoustic weights. Its full inference differs from Kokoro's distilled/decoder path. [Author](https://github.com/yl4579/StyleTTS2). |
| ZipVoice / Distill | Official Chinese/English releases; PT not listed. | **123M** flow-matching family plus waveform decoding; sherpa support does not change supported checkpoint language. Apache-2.0. [Author](https://github.com/k2-fsa/ZipVoice). |

FastSpeech2/HiFi-GAN and custom VITS checkpoints are architectures plus concrete acoustic/vocoder artifacts, not single comparable downloadable models. Add a specific Portuguese checkpoint only with its license, phonemizer, runtime and measurements. None of the exclusions above constitutes a claim that a model cannot be optimized for mobile; it means evidence does not justify selecting it first for this product goal.

## Benchmark gate

Measure identical pt-BR text and pronunciation acceptance on each target: load/cold TTFA, warm TTFA p50/p95, whole-pipeline RTF (phonemization through playable/encoded audio), peak RSS, model bytes, cancellation and sustained behavior. Use one model/process at a time, same output workload and default speech rate, explicit thread sweep, warm/cold trials and runtime/version/hash. Compare first audible PCM separately from chapter export. Retain failed runs and exclude unsupported checkpoints rather than silently substituting English. A lower neural parameter count or a newer quantized format is not sufficient evidence to select a fallback.
