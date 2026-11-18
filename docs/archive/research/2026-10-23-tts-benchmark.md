# Book TTS benchmark — consolidated evidence

Updated: 2026-10-23T19:19:29Z.

Measured on an Intel Mac, 2026-10-23. Terminal research only; no application integration or default change. No paid inference used. Filesystem/OS caches were not purged; remote model revisions and server-side caching are not exposed. Human pronunciation/naturalness and iOS 15/older Android runtime acceptance remain pending.

## Recommendation and consistent client policy

| Role | Candidate | Reason and limit |
| --- | --- | --- |
| Primary offline | Piper Faber PT-BR / Lessac EN | Portable candidate with competitive measured speed; mobile runtime and voice quality still require acceptance. |
| Automatic local fallback | Installed system voice | Prefer Luciana on Apple PT-BR when installed; platform voices differ. Browser native speech is listening-only. |
| Optional online | Edge Francisca PT-BR / Guy EN | Explicit consent; service limits and the observed long-job timeout require bounded jobs and recovery. The tested Edge client is local software using remote inference; it is not an offline model. |
| Further candidate | Pocket INT8 | Retain for listening and resident/mobile-engine evaluation; not established as a better PT-BR default. |

## Initial offline comparison

66/66 initial outputs validated. Three repetitions per language-specific passage; fresh processes. Timing includes startup, model load, synthesis and original-format file output, excluding decode verification. These are not normalized MP3-export or resident-engine timings.

| Engine | Passage | Median complete audio s | Median audio duration s |
| --- | --- | --- | --- |
| apple-luciana | akita-short | 1.23 | 9.04 |
| piper-faber | akita-short | 3.22 | 6.88 |
| kokoro-int8-pf_dora | akita-short | 21.93 | 7.30 |
| pocket-portuguese-fp32 | akita-short | 5.29 | 8.36 |
| pocket-portuguese-int8 | akita-short | 3.60 | 8.36 |
| pocket-portuguese-int8 | akita-paragraph | 11.41 | 32.04 |
| pocket-portuguese-fp32 | akita-paragraph | 15.41 | 32.92 |
| kokoro-int8-pf_dora | akita-paragraph | 53.60 | 23.87 |
| piper-faber | akita-paragraph | 4.43 | 23.59 |
| apple-luciana | akita-paragraph | 1.41 | 32.25 |
| apple-samantha | lotr-short | 1.51 | 10.24 |
| piper-lessac | lotr-short | 2.49 | 9.20 |
| kokoro-int8-af_heart | lotr-short | 26.71 | 8.62 |
| pocket-english_18m_2026-10-fp32 | lotr-short | 1.92 | 9.00 |
| pocket-english_18m_2026-10-int8 | lotr-short | 2.08 | 9.08 |
| kitten-nano-int8 | lotr-short | 9.34 | 11.29 |
| kitten-nano-int8 | lotr-paragraph | 26.35 | 31.20 |
| pocket-english_18m_2026-10-int8 | lotr-paragraph | 5.92 | 23.96 |
| pocket-english_18m_2026-10-fp32 | lotr-paragraph | 6.43 | 25.16 |
| kokoro-int8-af_heart | lotr-paragraph | 54.14 | 23.19 |
| piper-lessac | lotr-paragraph | 4.26 | 23.30 |
| apple-samantha | lotr-paragraph | 1.75 | 26.73 |

Piper runs use sherpa-onnx 1.13.8 and its converted Faber ONNX, not the application's separately checksum-validated original Faber artifact. Converted Faber SHA256: 956b4f1733903891c4ba0973d0603b2a3d8c09c8432fb3bb5203a90a7431daca; original application catalog SHA256: 858555e3a064209c57088fe6bd70c4c3dc54d03eaa00c45d5ecaf43a33f95aa7. Do not substitute these artifacts silently. Apple results use /usr/bin/say, not the app's Swift/FFI adapter. These are provider/model-family priorities, not measured app-adapter performance. Child RSS, where retained, excludes Apple helper services.

## Terminal concurrency comparison

local: 88/88 validated requests across 22 batches. Each batch uses four repeated short requests. Client/process overlap does not establish server worker count or phone feasibility.

| Configuration | Clients | Batch generation s | Median first non-silent PCM, request s | Statuses |
| --- | --- | --- | --- | --- |
| apple-luciana | 1 | 7.12 | not measured | {"validated":4} |
| apple-luciana | 2 | 3.15 | not measured | {"validated":4} |
| apple-samantha | 1 | 7.75 | not measured | {"validated":4} |
| apple-samantha | 2 | 4.17 | not measured | {"validated":4} |
| kitten-nano-int8 | 1 | 57.46 | not measured | {"validated":4} |
| kitten-nano-int8 | 2 | 23.05 | not measured | {"validated":4} |
| kokoro-int8-af_heart | 1 | 98.66 | not measured | {"validated":4} |
| kokoro-int8-af_heart | 2 | 46.92 | not measured | {"validated":4} |
| kokoro-int8-pf_dora | 1 | 58.78 | not measured | {"validated":4} |
| kokoro-int8-pf_dora | 2 | 48.72 | not measured | {"validated":4} |
| piper-faber | 1 | 20.74 | not measured | {"validated":4} |
| piper-faber | 2 | 11.38 | not measured | {"validated":4} |
| piper-lessac | 1 | 19.72 | not measured | {"validated":4} |
| piper-lessac | 2 | 13.39 | not measured | {"validated":4} |
| pocket-english_18m_2026-10-fp32 | 1 | 11.50 | not measured | {"validated":4} |
| pocket-english_18m_2026-10-fp32 | 2 | 6.23 | not measured | {"validated":4} |
| pocket-english_18m_2026-10-int8 | 1 | 11.30 | not measured | {"validated":4} |
| pocket-english_18m_2026-10-int8 | 2 | 6.23 | not measured | {"validated":4} |
| pocket-portuguese-fp32 | 1 | 15.73 | not measured | {"validated":4} |
| pocket-portuguese-fp32 | 2 | 13.04 | not measured | {"validated":4} |
| pocket-portuguese-int8 | 1 | 24.01 | not measured | {"validated":4} |
| pocket-portuguese-int8 | 2 | 13.73 | not measured | {"validated":4} |

remote: 48/48 validated requests across 12 batches. Each batch uses four repeated short requests. Client/process overlap does not establish server worker count or phone feasibility.

| Configuration | Clients | Batch generation s | Median first non-silent PCM, request s | Statuses |
| --- | --- | --- | --- | --- |
| edge-online-en | 1 | 11.26 | 0.85 | {"validated":4} |
| edge-online-en | 2 | 4.83 | 0.91 | {"validated":4} |
| edge-online-en | 4 | 2.57 | 0.96 | {"validated":4} |
| edge-online-pt | 1 | 7.81 | 0.84 | {"validated":4} |
| edge-online-pt | 2 | 4.52 | 0.94 | {"validated":4} |
| edge-online-pt | 4 | 2.03 | 0.87 | {"validated":4} |
| pocket-online-en | 1 | 13.28 | 0.84 | {"validated":4} |
| pocket-online-en | 2 | 11.51 | 1.05 | {"validated":4} |
| pocket-online-en | 4 | 12.23 | 1.06 | {"validated":4} |
| pocket-online-pt | 1 | 11.17 | 0.84 | {"validated":4} |
| pocket-online-pt | 2 | 8.95 | 0.94 | {"validated":4} |
| pocket-online-pt | 4 | 10.15 | 0.92 | {"validated":4} |

## Other free hosted demos

| Demo | Result | Complete downloaded audio s | HTTP |
| --- | --- | --- | --- |
| qwen-pt | validated | 16.44 | 200 |
| kitten-en | validated | 8.79 | 200 |
| chatterbox-pt | validated | 9.30 | 200 |
| voxcpm-pt | http_error | pending | 503 |

Qwen, Chatterbox and Kitten demos returned complete-file responses; these are single smoke requests, not sustained streaming/concurrency evidence. VoxCPM refusal/503 is preserved without retry. Public demo availability is not a production SLA or a guaranteed free API entitlement. No confirmed public Piper endpoint was available: localhost serving would measure local compute plus HTTP, not cloud inference.

## Whole chapter in one external generation job

| Engine | Result | Observed command s | Audio min | Generation/audio ratio |
| --- | --- | --- | --- | --- |
| apple-luciana | validated | 32.44 | 29.31 | 0.02 |
| piper-faber | validated | 89.88 | 21.86 | 0.07 |
| edge-online-pt | failed | 90.76 | unverified | unverified |

This is a separate export-throughput baseline using the same complete chapter text. Local voices load once per external job. Edge uses edge-tts 7.3.1 internal protocol splitting and a 90-second client deadline; it is not one giant SSML request. Completion excludes post-batch decoding. This baseline has no position-aware delivery or first-PCM timing and is not a substitute for the block-based listening experiment. Default speaking rates differ; compare text coverage and generation time alongside audio duration.

The Edge whole-job attempt failed after 90.76 seconds: asyncio.timeout expired at the configured 90-second client deadline while the SDK awaited WebSocket receive. The 120-second supervisor deadline did not fire. A 2,269,440-byte partial MP3 decodes as 378.24 seconds of audio; it is not a completed chapter. No explicit HTTP 429 or Retry-After was observed in that attempt. The user had already reported Edge rate limits: successful short trials do not refute that report, and throttling without an explicit response remains possible. This client had no frame timeline, so the underlying service delay is unresolved.

## Hybrid block size comparison

| Configuration | Valid/expected | Generate + persist s | Single MP3 + verification s | First complete block s | Replay gap 1x s | Replay gap 2x s |
| --- | --- | --- | --- | --- | --- | --- |
| hybrid-apple-luciana-c1 | 16/16 | 52.89 | not assembled | 1.19 | 0.00 | 0.00 |
| hybrid-apple-luciana-c2 | 16/16 | 35.82 | 44.21 | 1.40 | 0.00 | 0.00 |
| hybrid-edge-online-pt-c1 | 16/16 | 247.51 | not assembled | 2.06 | 0.00 | 12.61 |
| hybrid-edge-online-pt-c2 | 16/16 | 23.23 | 30.72 | 1.77 | 0.00 | 0.00 |
| hybrid-edge-online-pt-c4 | 16/16 | 11.22 | 18.70 | 1.96 | 0.00 | 0.00 |
| hybrid-piper-faber-c1 | 16/16 | 154.60 | not assembled | 3.08 | 0.00 | 5.08 |
| hybrid-piper-faber-c2 | 16/16 | 102.84 | 110.01 | 3.34 | 0.00 | 3.27 |

Hybrid plans preserve the same chapter and first two 96/351-character blocks, then coalesce remaining sentence-aligned blocks up to 2,000 characters: 16 blocks rather than 59. Local commands/encoding stay the same. Edge uses an archived variant of the same PCM probe with only its input guard extended from 500 to 3,000 characters; the maximum actual block is 1,999. This varies request/model-load overhead while retaining a short start. One run per case; no global optimum is established. Local concurrency is capped at two; online hybrid trials include one, two and four clients.

The main chapter configurations ran in fixed serial-then-parallel order. Edge's per-request latency also changed substantially between those periods, so the entire batch-time ratio cannot be assigned to concurrency alone. An additional late serial repetition was omitted to bound runtime at the user's request; server-side caching and deployment conditions remain uncontrolled.

## Full chapter and listening from the middle

Akita chapter 11, Como se mede uma IA: 24028 characters / 24648 UTF-8 bytes; SHA256 ed158c5ffb93c642e2926d3801b18c109e92be29f006b4e73aa6ad3b34da7b69. All text is retained across 59 blocks. First block limit 180 characters, subsequent limit 480; sentence/word boundaries preferred. The middle starts at character offset 11599. Next-chapter probe uses the first two blocks of chapter 12. Campaign: finished.

| Engine | Scenario | Validated/expected | Generate + persist blocks s | Complete MP3 + verification s | Audio min | First complete block s | Replay stalls 1x / 2x |
| --- | --- | --- | --- | --- | --- | --- | --- |
| apple-luciana | full-c1 | 59/59 | 109.79 | 128.23 | 29.17 | 1.64 | 0 / 0 |
| apple-luciana | full-c2 | 59/59 | 72.53 | 91.98 | 29.17 | 1.56 | 0 / 0 |
| apple-luciana | middle-c1 | 30/30 | 53.66 | 63.21 | 15.24 | 1.95 | 0 / 0 |
| apple-luciana | next-prefix-c1 | 2/2 | 4.27 | pending | 0.76 | 1.57 | 0 / 0 |
| piper-faber | full-c1 | 59/59 | 273.03 | 289.38 | 21.84 | 3.63 | 0 / 1 |
| piper-faber | full-c2 | 59/59 | 195.92 | 213.83 | 21.88 | 3.94 | 0 / 0 |
| piper-faber | middle-c1 | 30/30 | 147.58 | 156.78 | 11.35 | 6.30 | 0 / 0 |
| piper-faber | next-prefix-c1 | 2/2 | 11.28 | pending | 0.55 | 2.99 | 0 / 1 |
| edge-online-pt | full-c1 | 59/59 | 301.86 | 318.68 | 25.85 | 3.08 | 0 / 0 |
| edge-online-pt | full-c2 | 59/59 | 65.23 | 83.10 | 25.85 | 1.94 | 0 / 0 |
| edge-online-pt | middle-c1 | 30/30 | 64.62 | 74.40 | 13.48 | 2.44 | 0 / 0 |
| edge-online-pt | next-prefix-c1 | 2/2 | 9.46 | pending | 0.68 | 2.95 | 0 / 1 |

The export column includes post-batch block verification, MP3 stream-copy assembly and final assembled-file verification. First-block and batch times start after manifest validation; startup before that clock and gaps between separately invoked phases are excluded. Per-block complete-MP3 time is conservative relative to incremental delivery. Edge also records first decoded non-silent PCM, which is not speaker output. Original Edge MP3 is preserved; WAV providers are encoded as mono 24 kHz/48 kbps. Fresh processes intentionally include repeated model startup. Parallel full-chapter runs and serial runs are single observations, not p95 estimates.

| Middle-start engine | Lead s | Predicted next-chapter gap 1x s | Predicted next-chapter gap 2x s |
| --- | --- | --- | --- |
| apple-luciana | 60 | 0.00 | 0.00 |
| piper-faber | 60 | 0.00 | 0.00 |
| edge-online-pt | 60 | 0.00 | 0.00 |

Continuity and prefetch are offline trace replays using actual completion times and decoded durations, assuming immediate playback of complete blocks and a 60-second experimental lead. They do not exercise an actual player, Rust scheduler, variable network, mobile suspension or audio-route changes. On a long chapter, prefetch must follow remaining playable time; at a chapter tail shorter than generation latency it must begin immediately or expose a gap.

| Engine/scenario at 2x | One-block start s | One-block gap s | Two-block start s | Two-block gap s |
| --- | --- | --- | --- | --- |
| apple-luciana-full-c1 | 1.64 | 0.00 | 3.15 | 0.00 |
| apple-luciana-full-c2 | 1.56 | 0.00 | 2.00 | 0.00 |
| piper-faber-full-c1 | 3.63 | 1.99 | 7.94 | 0.00 |
| piper-faber-full-c2 | 3.94 | 0.00 | 5.60 | 0.00 |
| edge-online-pt-full-c1 | 3.08 | 0.00 | 7.37 | 0.00 |
| edge-online-pt-full-c2 | 1.94 | 0.00 | 2.13 | 0.00 |

The two-block replay is an illustrative startup-buffer tradeoff, not an implemented app default. A tiny first block can start quickly yet contain too little audio to cover the next cold model load at 2x. Prefer a playback-time-based buffer and measured generation speed; two blocks can represent very different durations. Faster chapter export does not by itself guarantee gap-free first playback.

## Position change and failure handling

| Engine job | Result | Cancel/reap s | Seek to target MP3 s | Exact new identity |
| --- | --- | --- | --- | --- |
| seek-final-apple-luciana | passed | 0.03 | 2.47 | true |
| seek-final-edge-online-pt | passed | 0.03 | 1.63 | true |
| seek-final-piper-faber | passed | 0.03 | 5.64 | true |

Host regressions exercise actual child-process overlap, timeout/reaping, cancellation, failure exit status, refusal preventing pending requests, Unicode/quoted text, ordered export and modified-source/audio rejection. Synthetic 401/429 fixtures prove stop behavior, not a real service rate threshold. Seek timing includes cancellation and new-batch startup, using persisted-MP3 monotonic telemetry when available; otherwise it is a replacement-batch upper bound. It is not app seek latency. Actual network refusal or timeout is preserved; no paid endpoint, quota evasion or intentional exhaustion is used.

## Edge timeout diagnosis and rollout limits

Source audit at isolated base 468e8b66 found distinct Edge paths: 25/60-second network-attempt deadlines, a raw 180/300-second chapter deadline, a length-aware typed-preferences path and a legacy five-second fallback branch. The active app build/dispatch branch was not identified. The five-second value is not a universal Edge chapter limit. Receiving frames does not necessarily reset an absolute deadline. These terminal clients do not reproduce the application's Rust transport; successful chapter runs cannot rule out an app-path timeout, missing turn.end, slow sink or ordering/backpressure problem.

| Serial Edge chapter metric | Requests | Median s | Maximum s | Over 5 s |
| --- | --- | --- | --- | --- |
| first_non_silent_pcm_request_s | 59 | 1.57 | 3.16 | 0 |
| complete_mp3_persisted_s | 59 | 4.31 | 9.09 | 19 |
| client_total_s | 59 | 4.32 | 9.10 | 19 |

In this completed serial chapter, 19/59 requests needed more than five seconds to persist the complete MP3, while every first non-silent PCM arrival was below five seconds. This makes an absolute five-second whole-operation budget a concrete suspect worth reproducing at the active Rust branch. It does not prove that branch was used, that its timing equals the Python client's phases, or that rate limiting caused the reported app timeout.

Proposed delivery policy: position/page-to-text mapping, ordered small blocks, priority for the selected position, chapter-only durable caching by default, next-chapter prefetch near the boundary, bounded per-provider concurrency and retries with Retry-After/backoff. Include book/chapter/text/model/voice/settings identity in cache keys; discard stale completions after seek. This is a design recommendation, not implemented behavior. Silence skipping remains deferred; generation speed and playback silence removal are different concerns.

## Acceptance matrix

| Concern | Evidence or remaining work |
| --- | --- |
| Full chapter and middle offset | Real text-to-MP3 jobs above; exact corpus hashes and ordered block manifests retained. |
| Playback continuity at 1x/2x | Trace replay only. Actual audio device, player buffering and decoder handoff remain untested. |
| Open page/player position mapping | Desired behavior accepted; EPUB page-to-text and current-player offset mapping were not exercised. |
| Next chapter | Real first-two-block generation; trigger/transition evaluated by trace replay with a 60-second experimental lead. |
| Seek and stale jobs | Terminal cancellation/replacement probe above; app queue identity and cross-job cache acceptance remain pending. |
| Provider limits and retries | Controlled refusal/timeout fixtures, bounded client concurrency and stop-on-refusal. Adaptive retries/Retry-After recovery and a real quota ceiling are not validated. |
| Very large chapters | One 24,028-character chapter measured. Larger chapters need bounded disk/queue budgets, checkpoints and cancellation without an unbounded chapter deadline. |
| Pause/background/offline transitions | Not exercised. Mobile suspension, interruptions, power/thermal limits and persisted resume need device acceptance. |
| Warm engines/connections | Not measured. Resident models/session reuse may change speed and RAM; fresh-process rankings cannot establish that result. |
| Voice fidelity and joins | Decoding/non-silence verified; blind listening, omitted/repeated speech, sentence prosody, MP3 joins and pronunciation still need review. |

No pronunciation-error rate, blind listening score, speaker-start latency, real-world rate-limit ceiling, energy/RAM-on-phone or mobile background acceptance has been established. No claim that all free online models were exhaustively tested: unavailable, paid, gated or undocumented routes are excluded with their reasons in the source research.

## Upstream references and provenance

Runtime/model/client source references: https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.13.8 ; https://huggingface.co/rhasspy/piper-voices ; https://github.com/rany2/edge-tts ; https://huggingface.co/kyutai/pocket-tts-without-voice-cloning . Exact installed assets, voice IDs, source revisions/hashes, endpoint schemas and licensing caveats are preserved with the private manifests and source reviews. A source-supported platform target is not measured device acceptance.

## Reproduction

Private corpus, audio, exact argv, model hashes, experiment plans and source snapshots are retained in the Obsidian AI Memory vault under `Curadas/Mac/Codex/epubtomp3/2026-10-23-book-tts`. No book text/audio or model weights are published with this documentation.

Set the task-specific variables below to the preserved, reviewed inputs and **new output directories inside that vault**. Omit the Edge manifest for an offline-only run. The chapter script performs synthesis; use the initial harness dry run to verify each manifest first.

```sh
mise run tts:benchmark:test -- --output "$TTS_NEW_CHECKS_DIRECTORY"
mise exec -- ruby scripts/tts_book_benchmark.rb --manifest "$TTS_LOCAL_MANIFEST" --dry-run
mise exec -- ruby scripts/tts_chapter_benchmark.rb \
  --manifest "$TTS_LOCAL_MANIFEST" --manifest "$TTS_EDGE_MANIFEST" \
  --text "$TTS_CHAPTER_TEXT" --sha256 "$TTS_CHAPTER_SHA256" \
  --next-text "$TTS_NEXT_CHAPTER_TEXT" --output "$TTS_NEW_OUTPUT_DIRECTORY"
```

`scripts/tts_parallel_benchmark.rb` executes a reviewed plan at a chosen concurrency; `scripts/tts_seek_benchmark.rb` measures cancellation/replacement; `scripts/tts_chapter_finalize.rb` joins only complete, ordered, hash-matching blocks; `scripts/tts_benchmark_consolidate.rb` regenerates this document and the private HTML. None of these commands builds or launches the app, changes provider defaults, downloads models or enables a paid service.
