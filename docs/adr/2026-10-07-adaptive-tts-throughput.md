# Adaptive TTS throughput

Status: Accepted

Use a provider-neutral feedback controller per conversion run for remote TTS
requests. Start from the fastest profile demonstrated reliable by live tests,
record per-chunk characters, duration, throughput, retries, and provider
pressure, then grow request size/concurrency only after a stable success window
and reduce both with cooldown after throttling or timeout. Keep provider-specific
response classification in its adapter so other rate-limited providers can use
the same policy; local engines do not consume remote request capacity. Preserve
audio order even when chunks are synthesized concurrently.

The initial Apple profile is 4,096 text characters and at most two in-flight
remote requests: a live two-chapter LOTR benchmark measured 315.3 seconds
serially and 144.0 seconds with two workers (2.19×). A 12,000-character request
timed out after 53.5 seconds including retry, so 12k is not a safe initial
profile. These are starting evidence, not universal provider guarantees; live
telemetry must be retained to validate later adaptation.

The 2026-10-07 macOS full-book run of *E não sobrou nenhum* synthesized all
113 chapters and produced 114 non-empty, probeable MP3 files (113 chapter
files and one temporary FFmpeg cover-embedding output). The trace recorded
250 chunk attempts: 237 successes and
13 recovered timeouts, with no explicit throttle responses. Successful chunk
events averaged 243.8 characters/second in aggregate. The trace exposed a
controller bug: tiny chapters (2 and 74 characters) were treated as slow
provider requests and quickly pushed the shared profile from 4,096 characters
/ 2 in-flight requests down to 2,048 / 1. Successful no-retry observations
smaller than the configured minimum chunk size are now excluded from capacity
decisions; retried fragments still count as pressure.

The 2026-10-07 macOS two-chapter-per-book smoke test passed all four playable
chapters in 165.1 seconds (including app/test setup). The two LOTR chapters
took 23.3 and 97.2 seconds; the two Christie smoke chapters took 2.6 and
2.5 seconds, with the Christie job completing in 7.4 seconds. The LOTR trace
had no retries or throttles, but its second chapter's 6,144-character requests
fell to 203–425 characters/second while the controller stayed at 6,144 / 2.
The previous 250 chars/second slow threshold therefore ignored sustained
degradation. The default slow threshold is raised to 450; two slow observations
reduce chunk size and concurrency, while growth still requires four requests
at or above 500 chars/second. This is provider-neutral service-time feedback,
not evidence of an Edge rate-limit response. Do not infer full-book duration
from this short sample or repeat a full synthesis just to benchmark it.

For long-running UI verification, reaching a displayed 100% is not the
terminal condition: the view can show the final chapter callback before the
worker persists its completed state and the UI finishes its post-conversion
handoff. XCTest must wait for that terminal record as well as validating the
expected audio artifacts. In this run all chapter callbacks and artifacts were
verified, but the test host exited on the 100% label before the terminal job
record was persisted, so that run did not verify its terminal handoff.
The follow-up focused macOS XCTest
`testLocalConversionFinalizationPersistsJobAndKeepsCompleteProgressVisible`
now exercises that exact finalization path with a completed manifest and
verifies the terminal snapshot, `LibraryStore` job ID after reload, and the
100% label after the view re-renders. This closes the controller-level
handoff check without repeating the expensive live conversion.

Recovery must be idempotent at the artifact boundary: a matching `queued` or
`running` job may resume, but a reused job ID with different input/provider
metadata and any terminal job must be rejected. Existing validated chapter
audio is reused byte-for-byte and must not be sent through cover embedding,
which re-encodes MP3. The macOS integration recovery of the same Christie job
completed all 113 chapters, persisted the manifest and terminal job state,
preserved every pre-existing MP3 hash, passed ZIP integrity validation, and
saved the job ID back to the imported library book. The coordinator must append
to `conversion.log`; truncating it destroys the chunk-speed and provider
pressure evidence needed for diagnosis and future tuning. The orphaned
FFmpeg cover temporary was excluded from the archive and removed after the
recovery checks passed.
