# Mac CPU TTS benchmark

Task: APP-20261016-TTS-MAC-RERUN. The user explicitly requested local terminal
execution and confirmed host stability on 2026-10-16. Simulator remains quarantined.
This research harness changes no app runtime, provider preferences or production data.

## Measurement plan

- Reuse the prior 116/655-character synthetic Portuguese fixtures; three fresh
  processes per candidate/input, alternating engine order. Two CPU threads for
  configurable engines. No cache purge or claim of cold filesystem/OS services.
- Bound every attempt to 120 seconds, preserve failures/timeouts and terminate
  only owned process groups. Serialize inference with the existing heavy-job lease.
- Record process-to-non-silent PCM callback/availability separately from model
  load, generation, complete file readiness, validation, audio duration, RTF and
  child RSS. WAV headers do not count as audio. No speaker playback is performed.
- Fully decode every successful artifact with ffmpeg and validate positive
  duration/non-silence. This does not prove correct spoken text or listening quality.
- Run eligible native CPU engines through prebuilt libraries/binaries. The
  Python wrapper measures Sherpa's native CPU implementation and is an isolated
  research tool, not a proposed product dependency.
- Qwen's prebuilt CLI provides complete-file output only; record that latency
  without labeling it streaming TTFA. Use matching backbone/projector GGUFs,
  verify their source LFS SHA-256, and retain reference-voice provenance.
- Keep app-suitability assessment separate from measured values and subjective
  voice quality; no mobile performance, MOS, p95, battery or thermal claim.

## Commands and assets

Use `mise run tts:mac:prepare` for compact package preparation and
`mise run tts:mac:benchmark` for synthesis. `TTS_MAC_ENGINES`,
`TTS_MAC_ITERATIONS` and `TTS_MAC_CORPORA` support a bounded setup pilot and
focused resumption; retain each distinct report directory instead of overwriting.

Sherpa package version 1.13.8 requires its matching `libonnxruntime.dylib`.
The protected `/usr/bin/time` clears DYLD environment variables, so preparation
links the matching dylib beside the isolated Sherpa Python extension, using
its existing rpath. Its Python package is installed
in `.reports/tts-mac-20261016/packages`, without changing the project environment.

Qwen source revision: `ggml-org/Qwen3-TTS-12Hz-1.7B-Base-GGUF`
`ca27d74bc954b73dadab5b71ca265d87fc861a7c`.
Backbone `Qwen3-TTS-12Hz-1.7B-Base-Q4_K_M.gguf`, SHA-256
`8d18c94acb2addd042f97da63c98be144eafa76d0d9495177eab65130cf85129`;
projector `mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf`, SHA-256
`6fd65188839bcd6ecc91b277ad471e22a0edfada4699a0fe82f1165c18cfcce2`.
Runtime: official llama.cpp b11669 macOS x64 release, built without Metal.

## Limits and exclusions

The technical score produced by `summarize.rb` is an interpretive operational
rubric for the tested host path, not a scientific quality score: 3 points times
the completed/validated fraction across both inputs, up to 4 points averaged
across attempts for whole-request realtime throughput, and up to 3 points
averaged across attempts for first available audio within 2 seconds. Slower
observations receive inverse-proportional points. An incomplete attempt earns
no throughput points; this scoring rule does not invent a zero-speed measurement.
Observed early PCM can earn start points even when the later export times out.
Missing audio earns no start points. Both inputs and every failure/timeout
contribute, so a quick short sample cannot conceal a stalled paragraph.
Memory is reported
separately because helper/cloud services are outside measured child RSS.
The rubric is not a pre-registered listening study or product acceptance gate.
`test_report.rb` exercises the report CLI's valid/censored results, duplicate
attempt identities, modified hashes, escaped artifacts, cancelled snapshots
and lost callback telemetry. These tooling regressions run in GitHub Actions,
without downloading models or starting native apps.

Times aggregate successful attempts only; every failed/timed-out attempt is
retained and counted separately. A partial success median is conditional on
success and cannot establish reliable latency. Three attempts are insufficient
for a dependable p95 or universal ranking. First-output measurements identify
PCM availability or a complete file, rather than actual speaker playback.

Setup pilots are retained separately: the initial Sherpa pilot exposed a missing
ORT rpath library; the first Pocket pilot exposed a missing HTTPX2 dependency.
Those preparation defects were corrected before the full study, and are not
misreported as provider/model timeouts in the 54-attempt study. Successful
Faber/Supertonic/Pocket setup audio was fully decoded before that study.

The official Python packages for Pocket require Torch >=2.5, Chatterbox pins
2.6, and VoxCPM requires >=2.5. PyTorch 2.2.x is the last official Mac Intel
wheel family. This blocks these official package paths on this host; it does
not establish that alternative native ports cannot work. Pocket is measured
through KevinAHM's pinned, Torch-free Portuguese ONNX wrapper instead, with
two ORT intra-op threads and an existing synthetic Edge reference. Its
`stream()` path yields PCM without speaker playback. No preset voice or user
recording is fetched during inference (`HF_HUB_OFFLINE=1`). The earlier Pocket
Portuguese iOS native adapter/assets were removed after its previous benchmark.

Pocket wrapper and assets revision: `58a6d00cf13d239b6748cb0769f35c580a8f606c`
in `KevinAHM/pocket-tts-onnx`. `prepare-pocket.rb` retains asset hashes.
The only wrapper subclass override sets ORT's intra-op count to two and
inter-op count to one; the upstream synchronous streaming logic is unchanged.
The reference is the first six seconds of the prior generated
`.reports/tts-host/20261013T200903Z/short-1-edge.mp3`, resampled to mono PCM16
24 kHz. Qwen uses this same synthetic reference. This conditioning is a
configuration choice, not a blind quality comparison.

Qwen 0.6B uses the matching pair from
`mradermacher/Qwen3-TTS-12Hz-0.6B-Base-GGUF`: talker Q4_K_M revision
`852b3c820a52bce25ab3e2f09edcb330440c0861`, SHA-256
`2dec66bcf1595f48a6dfb64c14e7e8437315e1606eba03094ed7372e60a4b9af`;
projector Q8_0 revision `417abaade79ee1858e3c4d8a42a8003718d828b3`, SHA-256
`202c1fbf3a0f00b7586ca45b8328d696cc6cd980c3798979eaa4fefe8efd8320`.
These are community conversions, distinct from Qwen's original weights.

Sources: [Pocket requirements](https://github.com/kyutai-labs/pocket-tts/blob/main/pyproject.toml),
[Chatterbox requirements](https://github.com/resemble-ai/chatterbox/blob/master/pyproject.toml),
[VoxCPM requirements](https://github.com/OpenBMB/VoxCPM/blob/main/pyproject.toml),
[PyTorch Mac Intel support](https://discuss.pytorch.org/t/why-no-macosx-x86-64-build-after-torch-2-2-2-cp39-none-macosx-10-9-x86-64-whl/204546).
