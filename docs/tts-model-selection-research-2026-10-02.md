# TTS model selection for EpubToMp3

## Scope and method

Research date: 2026-10-02. Goal: compare local/open TTS candidates for audiobook conversion by quality, throughput, footprint, language coverage, and fit with the existing Edge-first/Piper-fallback architecture. Primary sources are official repositories/model cards/docs. Published speed figures are not directly comparable across hardware; validate on representative Mac, Android, and server targets.

## Executive synthesis

Recommended product strategy:

1. Keep Edge-TTS as the default quality/speed path when network is available.
2. Add Kokoro-82M as the first local English candidate: unusually small, fast, permissive Apache-2.0, and likely a better audiobook-quality/CPU trade-off than Piper. Do not advertise it as multilingual until non-English voice packs and runtime support are verified.
3. Add MeloTTS as a CPU-oriented multilingual local candidate where its supported language/voice quality is sufficient; it is explicitly documented as real-time on CPU.
4. Treat Qwen3-TTS-12Hz-0.6B-CustomVoice as the strongest quality/coverage experiment, not the default mobile runtime: 10 languages including Portuguese, but materially larger and dependent on a PyTorch-class runtime. The 1.7B variant is a server/GPU quality tier.
5. Treat Chatterbox Multilingual as a quality/expressiveness server tier, not an embedded/mobile fallback: approximately 0.5B parameters, 23+ languages depending on release, and a heavier diffusion decoder.
6. Do not prioritize XTTS-v2 for this app: older, larger, slower, and its license/runtime footprint are less attractive than current alternatives.

## Comparison

| Candidate | Coverage | Quality potential | Speed/footprint | Best role | Main risk |
|---|---|---|---|---|---|
| Edge-TTS | Broad Microsoft voice catalog; cloud | High and consistent | Fast when network is good; zero local model | Default online engine | Network, rate limits, service dependency |
| Piper | Many per-language voices | Good/variable; voice-dependent | Excellent CPU/offline; small per voice | Reliable offline fallback | Quality varies; separate model per language/voice |
| Kokoro-82M | English manifest currently verified; other voices pending | High for its size; validate each voice | 92.9 MB verified quantized package plus runtime | Candidate local default after runtime validation | Runtime and non-English voice support still pending |
| MeloTTS | EN variants, ES, FR, ZH, JA, KO and others per official docs | Good, especially single-language voices | Officially CPU real-time; model per language | Local single-language engine | Less broad coverage; voice quality varies |
| Qwen3-TTS 0.6B | 10 major languages incl. PT | Very high potential; controllable | Low-latency streaming claims, but 0.6B runtime/weights are heavy for phones | Server or high-end desktop multilingual tier | PyTorch/deployment size, RAM, mobile feasibility |
| Qwen3-TTS 1.7B | Same 10 languages | Higher quality/control than 0.6B | Server/GPU tier | Premium audiobook/server mode | Too large for ordinary mobile/CPU |
| Chatterbox Multilingual | 23+ languages depending on version | Expressive, high quality | ~0.5B plus diffusion decoder; server-oriented | Premium server fallback | Heavy local runtime, latency, long-form stability |
| XTTS-v2 | 13 languages | Good and voice cloning capable | ~1.8GB weights reported by model ecosystem; GPU preferred | Compatibility/voice-clone experiment only | Older stack, larger footprint, license/runtime complexity |

## Language detection and routing

Detect language once from a cleaned sample of the book (title/front matter excluded; combine several chapter excerpts). Use a confidence threshold and keep a manual override. Route by language rather than automatically choosing a multilingual model:

- Portuguese, Spanish, French, German, Italian, Japanese, Korean, Chinese: test Edge, then MeloTTS where a strong voice exists; use Piper as the robust offline fallback. The current verified Kokoro manifest is English-only.
- Less-covered languages: use Edge first, then Piper voice catalog. Do not route blindly to Kokoro/MeloTTS.
- Mixed-language books: detect per chapter or paragraph only when confidence changes materially; otherwise retain the book's dominant voice for consistency.

Recommended policy: `language_detector -> voice registry -> engine candidates(language, platform, quality profile) -> health/performance fallback`.

## Suggested profiles

### Balanced default

`Edge-TTS -> verified Kokoro voice or MeloTTS -> Piper`

Use only after measuring the exact voice/model. Keep one voice stable across a book. For a fully offline run, select Kokoro/MeloTTS if supported and otherwise Piper.

### Maximum local quality

`Qwen3-TTS-12Hz-0.6B -> Kokoro/MeloTTS -> Piper`

Only on desktop/server hardware with a warm model cache. Benchmark long chapters, memory, and failure recovery before enabling by default.

### Premium server

`Edge-TTS -> Qwen3-TTS-12Hz-1.7B or Chatterbox -> Piper`

Use for quality experiments and optional premium mode, not the mobile baseline.

### Mobile

`Edge-TTS direct -> Kokoro or Piper only if native runtime is proven stable for that API/ABI -> controlled unavailable result`

Do not embed Qwen/Chatterbox until memory, startup time, binary size, thermal behavior, and API compatibility are demonstrated on real target devices. This is especially important given the existing Android API 28 native-runtime crash history.

## What must be benchmarked locally

Create a fixed 5-10 minute corpus per language containing narration, dialogue, punctuation, numbers, abbreviations, and long paragraphs. Measure:

- MOS-like blind listening score from the same reviewers;
- real-time factor and chars/second on Mac, server, and representative Android;
- peak RSS/VRAM and cold-start time;
- model/package download size and installed size;
- word error rate from ASR, plus truncation/hallucination rate;
- failure rate over 30+ chapters and recovery time;
- voice consistency across chapters;
- license and redistribution constraints.

Do not infer that a published first-packet latency equals long-form audiobook throughput. Qwen's official streaming documentation explicitly notes that its current mode simulates streaming by processing the complete text input; its technical report benchmarks optimized GPU infrastructure.

## Decision

The best practical three-way balance is likely:

- Online: Edge-TTS remains first choice.
- Local CPU/small footprint: Kokoro-82M, if the selected language/voice passes Portuguese and audiobook tests; otherwise MeloTTS for supported languages.
- Universal offline safety net: Piper.
- High-quality multilingual server experiment: Qwen3-TTS 0.6B first; 1.7B only as premium GPU/server.

This is a recommendation based on official capabilities and architecture, not a verified head-to-head benchmark on this repository's hardware.

## Runtime feasibility update (2026-10-02)

A more viable embedded runtime candidate than the abandoned `kokoroxide` path is
`sherpa-onnx`:

- the official project documents offline TTS and Kokoro-82M support;
- the official C API exposes `SherpaOnnxCreateOfflineTts` and model-family-specific
  configuration, which is suitable for a thin Rust FFI adapter;
- crates.io currently publishes `sherpa-onnx` 1.13.8 and
  `sherpa-onnx-sys` 1.13.8 under Apache-2.0, with static/shared features;
- the official project explicitly lists Android and embedded/offline usage.

Recommended next implementation slice:

1. Add `sherpa-onnx-sys` behind a dedicated `kokoro-sherpa-runtime` feature in
   `converter-core`, without enabling it in the baseline builds.
2. Wrap only the offline Kokoro TTS C API in a Rust-owned lifecycle: create,
   synthesize one chapter, write WAV/PCM, and destroy the handle.
3. Keep the catalog model disabled until startup and one real synthesis call pass.
4. Build the native archive independently for Android, Apple, Linux, and Windows;
   never assume the crates.io host archive is valid for every target.
5. Only then publish Kokoro manifests and connect the model manager's install action.

This is an implementation path, not yet runtime proof. It still requires native
archive/toolchain validation and real audio synthesis on each target.

## Additional primary sources

- sherpa-onnx TTS documentation: https://k2-fsa.github.io/sherpa/onnx/tts/index.html
- sherpa-onnx Kokoro documentation: https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/kokoro.html
- sherpa-onnx C TTS API: https://k2-fsa.github.io/sherpa/onnx/c-api/html/tts.html
- sherpa-onnx Kokoro C example: https://github.com/k2-fsa/sherpa-onnx/blob/master/c-api-examples/kokoro-tts-en-c-api.c
- sherpa-onnx Rust crate: https://crates.io/crates/sherpa-onnx/1.13.8
- sherpa-onnx raw FFI crate: https://crates.io/crates/sherpa-onnx-sys/1.13.8

- Kokoro official repository/model link: https://github.com/hexgrad/kokoro
- Piper official repository and voice samples: https://github.com/rhasspy/piper and https://rhasspy.github.io/piper-samples/
- Piper voice documentation: https://tderflinger.github.io/piper-docs/about/voices/download/
- Qwen3-TTS official repository/model documentation: https://github.com/QwenLM/Qwen3-TTS
- Qwen3-TTS technical report: https://arxiv.org/abs/2601.15621
- Qwen3-TTS streaming guide: https://qwenlm-qwen3-tts.mintlify.app/guides/streaming
- Chatterbox official repository: https://github.com/resemble-ai/chatterbox
- Chatterbox multilingual model card: https://build.nvidia.com/resembleai/chatterbox-multilingual-tts/modelcard
- MeloTTS official repository: https://github.com/myshell-ai/MeloTTS
- MeloTTS official documentation: https://docs.myshell.ai/technology/melotts
- XTTS-v2 model card: https://huggingface.co/coqui/XTTS-v2

## Verified Kokoro ONNX artifact reconnaissance

The official Kokoro repository publishes Apache-2.0 weights. The `onnx-community/Kokoro-82M-ONNX` Hugging Face repository provides an ONNX packaging suitable for investigation, including `onnx/model_quantized.onnx` (92,360,543 bytes), `tokenizer.json`, and per-voice binary files. The quantized model SHA-256 was independently verified on 2026-10-02 as `0d55b15d4b735d61a21b0105136bc81b8768c4db94753193c19354fa863cd556`.

This artifact is not yet enabled as a production download: synthesis requires the model, tokenizer, voice assets, and a compatible ONNX Runtime integration as one tested package. The current Rust ModelStore accepts one artifact plus one checksum, so enabling only the ONNX file would create an incomplete installation. The next slice must install the complete asset manifest atomically and validate synthesis on each target before promoting Kokoro from catalog candidate to default runtime.

## Rust runtime compatibility checkpoint

The first Rust candidate, `kokoroxide 0.1.5`, cannot currently be used as a reproducible dependency: it requires `ort 1.16`, whose published versions are yanked from crates.io. The current `ort 2.0.0-rc.12` line also does not publish a prebuilt binary for this project's Intel macOS target, and its dynamic-loading mode requires the application to package a matching ONNX Runtime library. Therefore Kokoro remains cataloged and downloadable only as an unactivated candidate; Piper remains the safe local fallback until a maintained cross-platform runtime is integrated and exercised with real audio.

## sherpa-onnx Kokoro package verification

The official sherpa-onnx `tts-models` release publishes complete model packages whose layout matches the C API adapter (`model.onnx`, `voices.bin`, `tokens.txt`, and `espeak-ng-data`), unlike the Hugging Face ONNX packaging described above. Verified release metadata from the GitHub API:

| Package | Download bytes | SHA-256 | Intended use |
|---|---:|---|---|
| `kokoro-int8-en-v0_19.tar.bz2` | 103,248,205 | `c9f0dd393615805b0bab050c340834d5e684e732aec91c0e860cd30e982c08bd` | First CPU/desktop smoke test |
| `kokoro-en-v0_19.tar.bz2` | 319,625,534 | `912804855a04745fa77a30be545b3f9a5d15c4d66db00b88cbcd4921df605ac7` | Higher-quality English |
| `kokoro-int8-multi-lang-v1_1.tar.bz2` | 147,031,220 | `a1e94694776049035c4f2c6529f003aaece993c76aae9a78995831c3c4dcafc6` | Multilingual CPU candidate |

Source: `https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models`.

These are archive artifacts, not yet catalog entries: ModelStore must add verified archive extraction with path-traversal protection and atomic directory publication before exposing them in Settings. The int8 English package is the next smoke-test candidate because it minimizes download and runtime cost while preserving the official sherpa layout.

