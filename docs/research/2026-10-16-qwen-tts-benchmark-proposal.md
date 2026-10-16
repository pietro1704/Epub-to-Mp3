# Qwen TTS candidates and benchmark proposal

Date: 2026-10-16. Task: APP-20261016-TTS-BENCHMARK-CONSENSUS.
Status: draft for discussion with Pietro; no agreed protocol or benchmark execution.

## Scope and latest Qwen releases

The request is to add Qwen to the comparison, present candidates before testing,
and iterate on the benchmark design. This note changes no provider defaults or
saved preferences. Earlier inventory/default recommendations are historical;
current project policy still selects Piper Faber unless the user changes it.

The latest hosted TTS confirmed in official documentation is
`qwen-audio-3.1-tts-flash`, a paid API with a time-limited free allowance.
No public official weights were found for this hosted model. This is distinct
from the open-weight Qwen3-TTS family; do not transfer its Apache license to
hosted models. Sources: [HTTP API](https://www.alibabacloud.com/help/en/model-studio/qwen-audio-tts-http-api),
[pricing](https://www.alibabacloud.com/help/en/model-studio/model-pricing),
[voices](https://help.aliyun.com/en/model-studio/qwen-audio-tts-voice-list).

Qwen3-TTS offers 0.6B and 1.7B Base/CustomVoice checkpoints and 1.7B VoiceDesign.
Official weights use Apache-2.0, with Portuguese among ten supported languages.
Local inference has no per-request model/API charge; compute, electricity and
hosting still cost resources. Base uses reference audio for voice cloning;
CustomVoice offers predefined speakers. None of its listed native speaker
languages guarantees a Brazilian accent. The advertised streaming latency is
not an app/phone measurement. Sources:
[official repository](https://github.com/QwenLM/Qwen3-TTS),
[0.6B Base](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-0.6B-Base),
[1.7B Base](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-Base),
[0.6B CustomVoice](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice),
[1.7B CustomVoice](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice).

The official reference implementation uses Python/PyTorch; this does not prove
a suitable embedded Rust/native mobile backend. Count tokenizer/codec assets
and total inference memory, not just headline parameter counts. Quantization
and backend changes are separate configurations and need quality checks.

Qwen-Audio-3.0-TTS has a July 2026 report and predates the hosted 3.1 model.
[Report](https://arxiv.org/abs/2607.23938).
For the user's Qwen4 question, the official Qwen3.8-Flash-Next model card calls
it an experimental preview of the architecture for Qwen4. It is a text/vision
language model, not a Qwen4 TTS release:
[official model card](https://huggingface.co/Qwen/Qwen3.8-Flash-Next).

## Candidate list before any benchmark

This is an eligibility/triage list, not a measured ranking. Every candidate
needs exact checkpoint, license, runtime, voice, version and hashes before testing.

| Candidate/configurations | Intended role | Eligibility caveat |
| --- | --- | --- |
| Piper `pt_BR-faber-medium`; `pt_BR-edresson-low` | Current product baseline and compact alternative | Review engine and individual voice licenses separately |
| Installed Apple AVSpeechSynthesizer / Android TextToSpeech pt-BR | Per-platform no-paid-API controls | Record exact installed voice and offline availability; platforms are separate comparisons |
| Kokoro 82M v1.0: `pf_dora`, `pm_alex`, `pm_santa` | Compact quality challenger | Voice is a separate configuration; backend affects cost |
| Pocket TTS Portuguese | CPU/streaming challenger | Pin Portuguese configuration, voice license and runtime |
| Supertonic 3 Portuguese | Compact multilingual challenger | OpenRAIL-M weights; upstream archived, maintenance matters |
| Qwen3-TTS-12Hz-0.6B-CustomVoice / Base | Smaller Qwen challenger | Base requires a consented/licensed reference; evaluate Brazilian accent |
| Qwen3-TTS-12Hz-1.7B-CustomVoice / Base | Open Qwen quality ceiling | Native feasibility and memory remain unmeasured |
| Chatterbox Multilingual V3, official pt-BR package | Brazilian multilingual quality challenger | Pin package and runtime; do not substitute English Nano/Turbo |
| VoxCPM2 Portuguese | Larger-model quality ceiling | Do not infer weak-phone viability from GPU timings |
| eSpeak NG / RHVoice Portuguese | Optional low-resource controls | Evaluate narration quality and redistribution terms |
| Edge pt-BR | Optional existing online reference | Network/service dependence; never an implicit fallback or permanent-free guarantee |
| Qwen-Audio-3.1-TTS-Flash | Optional paid online reference | Excluded from a strict no-paid-API shortlist; requires separate cost/credential agreement |

Qwen VoiceDesign is optional for a later narrator-design experiment rather than
a mandatory first-round configuration. Models lacking an official Portuguese
checkpoint and research/noncommercial-only models should not silently enter
the production-eligible shortlist.

Sources for existing candidates and license qualifications:
[prior compact inventory](2026-10-13-compact-tts-models.md),
[prior platform inventory](2026-10-13-platform-cloud-tts.md),
[Kokoro voices](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md),
[Pocket](https://github.com/kyutai-labs/pocket-tts),
[Supertonic](https://github.com/supertone-oss-archive/supertonic),
[Chatterbox pt-BR](https://huggingface.co/ResembleAI/Chatterbox-Multilingual-pt-br),
[VoxCPM](https://github.com/OpenBMB/VoxCPM),
[Piper voice](https://huggingface.co/rhasspy/piper-voices/blob/main/pt/pt_BR/faber/medium/MODEL_CARD).

## Proposed protocol to discuss

First decide whether the product needs one portable winner or per-device choices.
Suggested direction: an offline weak-phone tier and a desktop/high-quality tier,
with optional cloud comparisons reported separately. Use a quality/latency/memory
tradeoff frontier rather than selecting solely by a weighted overall score.

1. Eligibility: licensing, pt-BR pronunciation, explicit model installation,
   native/Rust integration feasibility and realistic device memory.
2. Blind listening: identical short passages covering Brazilian narration,
   dialogue, names, dates, numbers, abbreviations, punctuation and mixed-language
   text. Randomize labels/order, normalize listening loudness, retain raw audio,
   and rate intelligibility, naturalness, accent, prosody and listening fatigue.
   Reference-voice models use a documented consented/licensed clip; record
   conditioning separately from models requiring none.
3. Timing: separately measure cold load, warm generation, first non-silent PCM,
   first playable segment through the app, export completion, characters/second
   and RTF. Use the same text and a matched speech-rate range; retain actual
   audio durations. Distinguish fixed-workload comparison from separately tuned
   best-performing configurations.
4. Reliability/resources: total attributable memory including services/codecs,
   download/disk bytes, CPU, sustained throttling, energy, stalls, omissions,
   repetition/hallucination, cancellation latency and resume/job identity.
   Keep failures/timeouts in results. ASR/WER can flag fidelity problems but
   cannot substitute for blind human quality/accent assessment.
5. Stages: bounded short-text triage, then sustained trials for finalists, then
   real-app integration verification on the agreed physical targets. Randomize
   serial engine order and predeclare cold/warm definitions and repetitions.
   Small trial counts do not support strong p95 claims.

No thresholds, weights, target devices, corpus, trial counts, downloads or
device actions are approved by this draft. Preserve the project's maximum two
chapters per book unless the user explicitly requests whole-book synthesis.
GitHub runner performance is useful screening evidence, not phone performance.

## Verification and safety

Official-source research and remote document inspection only. No model assets
were downloaded and no synthesis, benchmark, test suite, build, app launch,
Simulator or device action ran for this request. Host panic/Intel Simulator
safety restrictions remain in force. The local checkout was not edited.
This documentation is a discussion draft; runtime acceptance remains open.
