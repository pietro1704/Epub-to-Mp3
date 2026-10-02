# TTS model selection for EpubToMp3

## Scope and method

Research date: 2026-10-02. Goal: compare local/open TTS candidates for audiobook conversion by quality, throughput, footprint, language coverage, and fit with the existing Edge-first/Piper-fallback architecture. Primary sources are official repositories/model cards/docs. Published speed figures are not directly comparable across hardware; validate on representative Mac, Android, and server targets.

## Executive synthesis

Recommended product strategy:

1. Keep Edge-TTS as the default quality/speed path when network is available.
2. Add Kokoro-82M as the first local single-language/selected-language candidate: unusually small, fast, permissive Apache-2.0, and likely a better audiobook-quality/CPU trade-off than Piper for supported languages.
3. Add MeloTTS as a CPU-oriented multilingual local candidate where its supported language/voice quality is sufficient; it is explicitly documented as real-time on CPU.
4. Treat Qwen3-TTS-12Hz-0.6B-CustomVoice as the strongest quality/coverage experiment, not the default mobile runtime: 10 languages including Portuguese, but materially larger and dependent on a PyTorch-class runtime. The 1.7B variant is a server/GPU quality tier.
5. Treat Chatterbox Multilingual as a quality/expressiveness server tier, not an embedded/mobile fallback: approximately 0.5B parameters, 23+ languages depending on release, and a heavier diffusion decoder.
6. Do not prioritize XTTS-v2 for this app: older, larger, slower, and its license/runtime footprint are less attractive than current alternatives.

## Comparison

| Candidate | Coverage | Quality potential | Speed/footprint | Best role | Main risk |
|---|---|---|---|---|---|
| Edge-TTS | Broad Microsoft voice catalog; cloud | High and consistent | Fast when network is good; zero local model | Default online engine | Network, rate limits, service dependency |
| Piper | Many per-language voices | Good/variable; voice-dependent | Excellent CPU/offline; small per voice | Reliable offline fallback | Quality varies; separate model per language/voice |
| Kokoro-82M | Smaller multilingual set; voice/language dependent | High for its size; validate PT-BR specifically | Excellent candidate for CPU/mobile; 82M | Local default for supported language | Coverage and mobile packaging/runtime need validation |
| MeloTTS | EN variants, ES, FR, ZH, JA, KO and others per official docs | Good, especially single-language voices | Officially CPU real-time; model per language | Local single-language engine | Less broad coverage; voice quality varies |
| Qwen3-TTS 0.6B | 10 major languages incl. PT | Very high potential; controllable | Low-latency streaming claims, but 0.6B runtime/weights are heavy for phones | Server or high-end desktop multilingual tier | PyTorch/deployment size, RAM, mobile feasibility |
| Qwen3-TTS 1.7B | Same 10 languages | Higher quality/control than 0.6B | Server/GPU tier | Premium audiobook/server mode | Too large for ordinary mobile/CPU |
| Chatterbox Multilingual | 23+ languages depending on version | Expressive, high quality | ~0.5B plus diffusion decoder; server-oriented | Premium server fallback | Heavy local runtime, latency, long-form stability |
| XTTS-v2 | 13 languages | Good and voice cloning capable | ~1.8GB weights reported by model ecosystem; GPU preferred | Compatibility/voice-clone experiment only | Older stack, larger footprint, license/runtime complexity |

## Language detection and routing

Detect language once from a cleaned sample of the book (title/front matter excluded; combine several chapter excerpts). Use a confidence threshold and keep a manual override. Route by language rather than automatically choosing a multilingual model:

- Portuguese, English, Spanish, French, German, Italian, Japanese, Korean, Chinese: test Edge, then Kokoro/MeloTTS where a strong voice exists; use Piper as the robust offline fallback.
- Less-covered languages: use Edge first, then Piper voice catalog. Do not route blindly to Kokoro/MeloTTS.
- Mixed-language books: detect per chapter or paragraph only when confidence changes materially; otherwise retain the book's dominant voice for consistency.

Recommended policy: `language_detector -> voice registry -> engine candidates(language, platform, quality profile) -> health/performance fallback`.

## Suggested profiles

### Balanced default

`Edge-TTS -> Kokoro-82M or MeloTTS -> Piper`

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

## Sources

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
