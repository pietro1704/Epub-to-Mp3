# Intel Mac TTS benchmark

Date: 2026-10-16. Task: APP-20261016-TTS-MAC-RERUN.

The explicitly authorized terminal study completed **54 attempts**: **46 generated
artifacts passed full ffmpeg decoding, positive duration and non-silence checks;
8 attempts reached the 120-second supervisor deadline**. There were no other
candidate-process failures. All 54 attempt identities are unique and match the
requested engine/input/iteration product; all 46 successful artifact hashes
were independently checked again after copying to persistent project storage.

This is a host experiment, not app/mobile/Simulator acceptance. No app build,
Simulator/device action, audible playback or provider-preference change occurred.

## Environment and protocol

- Intel Core i5-8259U at 2.30 GHz, 8 GiB RAM, macOS 15.8.1, x86_64.
- Same synthetic Portuguese inputs as the earlier study: 116-character short
  passage and 655-character paragraph; three fresh processes per engine/input.
- Two CPU threads for configurable local engines; sequential attempts under
  the existing exclusive heavy-job lease. Engine order alternates by block.
- Fresh process does not imply cold filesystem/model pages or cold OS speech
  services. Downloads, preparation and validation are outside synthesis timings.
- Request times include process/interpreter startup and model initialization.
  Native model-load/generation/callback intervals are also retained separately.
- Run: 21:53:51–22:30:33 UTC, 36 min 42 s including all attempts, deadlines,
  validation and orchestration. This total is not synthesis throughput.
- Host load average observed at attempt boundaries ranged from **4.45 to
  308.33**. Other user workloads remained running. This severe, changing
  contention prevents interpreting this table as an intrinsic model ranking.

## Measured results

Times and rates are medians of successful attempts; failures/timeouts remain
counted rather than being silently discarded. The throughput column uses the
same short input for every candidate. Paragraph medians with only two successes
are conditional on success. These sample counts do not establish p95 or an SLA.

| Configuration | Short chars/s | First available short audio (s) | Complete paragraph (s) | Observed child peak MiB | Validated / attempted | Timeouts | Technical path score /10 |
| --- | ---: | ---: | ---: | ---: | --- | ---: | ---: |
| Apple Luciana, installed system voice | 49.43 | 2.18 | 1.93 | 41 | 6/6 | 0 | 9.7 |
| Piper Faber medium, Sherpa FP32 | 32.85 | 3.03 | 7.17 | 275 | 6/6 | 0 | 8.8 |
| Piper Edresson low, Sherpa FP32 | 32.07 | 3.13 | 7.85 | 265 | 6/6 | 0 | 8.3 |
| Edge FranciscaNeural, existing Rust Debug probe | 50.53 | 2.30 | 15.15 | 12 | 6/6 | 0 | 8.3 |
| Pocket Portuguese 6-layer, mixed int8/FP32 ONNX | 11.41 | 4.33 | 26.73 | 910 | 6/6 | 0 | 7.8 |
| Supertonic 3 int8, sid=0, 8 steps, lang=pt | 17.69 | 6.45 | 24.60 | 462 | 6/6 | 0 | 7.1 |
| Kokoro v1.0 int8, Dora sid=42, lang=pt-br | 5.13 | 8.98 | 83.30 | 343 | 5/6 | 1 | 4.4 |
| Qwen3-TTS 0.6B Base, Q4_K_M + matching Q8 projector | 2.07 | 58.32 | Not completed | 2,460 | 2/6 | 4 | 1.3 |
| Qwen3-TTS 1.7B Base, Q4_K_M + matching Q8 projector | 1.35 | 86.20 | Not completed | 2,653 | 3/6 | 3 | 1.8 |

First available audio is **non-silent PCM callback/data availability** for the
local callback engines and Apple, but **complete-file availability** for Edge
and Qwen. The prebuilt Qwen CLI does not expose external streaming. None of
these values measures first audible speaker output or the app's play button.
Memory is the peak observed child process in completed attempts, not total
engine/system memory; Apple helper services and Edge cloud inference are excluded.
Timed-out processes may have had unmeasured higher memory peaks.

The score is a transparent, interpretive operational rubric across all six
attempts: 3 points for validated completion fraction, up to 4 for realtime
whole-request throughput, and up to 3 for first available audio within 2 seconds.
Slower observations receive inverse-proportional points; incomplete work earns
no throughput points without inventing a zero-speed measurement. Observed early
PCM can still earn start points on a timed-out export. The full formula is in
[summary.json](tts-mac-20261016/summary.json) and `summarize.rb`.
It is not a pre-registered quality study, MOS, app-readiness certificate or
mobile score. Listening quality and integration effort are outside this rubric.

## Findings relevant to app selection

Faber is the next portable offline candidate I would prioritize for app-level
verification: all six attempts completed, paragraph readiness median was 7.17 s,
and no skipped-phoneme warnings were emitted. Its measured native first PCM
callback median was **0.230 s after entering generation**, versus **3.03 s from
fresh process launch**; those are different intervals. This does not prove the
app's UI latency or performance on a phone. Apple is a promising per-platform
control, with helper-memory and platform restrictions still relevant.

Edresson emitted **75 `Skip unknown phonemes` messages for U+0303** across the
six attempts. Successful decoding does not resolve the pronunciation question.
Edge's paragraph completion range was **2.16–87.73 s**; six successes do not
establish stable network/provider latency. Its reused probe hash matches the
2026-10-13 probe; this study did not independently establish its build-source HEAD.

Qwen 0.6B completed two short inputs in **46.92–69.72 s**; 1.7B completed all
three in **77.86–112.53 s**. Both generated decodable, non-silent WAV files.
Neither completed any of the three paragraph attempts inside 120 s. These
results argue against this particular CPU/batch-CLI path for responsive app
narration, without establishing the capabilities of different backends,
CustomVoice checkpoints, GPUs or phones. No voice naturalness, Brazilian accent,
text completeness, ASR/WER, buffer stalls, battery or thermal study was performed.

## Runtime provenance and limits

Sherpa 1.13.8 used its matching native ONNX Runtime 1.28.2 CPU library. Pocket
used the pinned KevinAHM Portuguese ONNX wrapper/export with ONNX Runtime 1.23.2,
without Torch. Qwen used the official prebuilt llama.cpp b11669 macOS x64 CPU
binary, built without Metal. Its talker/projector pairs were checked against
the source LFS SHA-256 before execution and checked again after the study.
Both Qwen and Pocket used the same six-second synthetic Edge reference,
not a recording of a person. See the [protocol](tts-mac-20261016/README.md),
[environment](tts-mac-20261016/environment.json) and provenance JSON files.

Chatterbox and VoxCPM were not executed: their official Python paths require
Torch >=2.5, and a current PyPI wheel compatibility check for this Intel/Python
3.12 environment offered only Torch 2.2.0–2.2.2. This does not rule out alternative
native ports. Android system voices, optional eSpeak/RHVoice controls, Qwen
CustomVoice and the paid hosted Qwen-Audio-3.1 API were not measured in this run.

## Evidence and verification

- [All attempt timings and identities](tts-mac-20261016/report.json).
- [Aggregated metrics and scoring formula](tts-mac-20261016/summary.json).
- [CSV](tts-mac-20261016/results.csv).
- [Qwen model fingerprints](tts-mac-20261016/qwen-provenance.json),
  [Edge probe identity](tts-mac-20261016/edge-provenance.json),
  [Pocket assets](tts-mac-20261016/pocket-provenance.json),
  [phoneme warning counts](tts-mac-20261016/phoneme-warning-counts.json).

The persistent local evidence directory is
`ios/EpubToMp3/.reports/tts-mac-20261016/20261016T215351Z/`: generated audio,
stdout/stderr/decode logs, original immutable raw report, copied execution
sources verified against the recorded harness hashes, normalized archival report,
reference audio/provenance and software inventory. Models remain isolated in the
temporary research checkout; no assets were installed into the production app.
The repository snapshots contain timings/provenance, not the audio or weights.

Executed `mise run tts:mac:benchmark`. Its final exit status was 1 because eight
candidates/attempts timed out; the harness retained all 54 terminal records.
`summarize.rb` exited 0 on the original and archived study and verified all
46 successful artifact hashes. All callback-engine successful rows retained
their parent non-silent PCM telemetry. Local test suites/builds were not run;
the user's local exception covered this terminal benchmark and its preparation.
Simulator acceptance remains blocked by the existing quarantine.
