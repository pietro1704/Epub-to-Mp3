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
113 chapters and produced 114 non-empty, probeable MP3 files (including its
extra cover track). The trace recorded 250 chunk attempts: 237 successes and
13 recovered timeouts, with no explicit throttle responses. Successful chunk
events averaged 243.8 characters/second in aggregate. The trace exposed a
controller bug: tiny chapters (2 and 74 characters) were treated as slow
provider requests and quickly pushed the shared profile from 4,096 characters
/ 2 in-flight requests down to 2,048 / 1. Successful no-retry observations
smaller than the configured minimum chunk size are now excluded from capacity
decisions; retried fragments still count as pressure.

For long-running UI verification, reaching a displayed 100% is not the
terminal condition: the view can show the final chapter callback before the
worker persists its completed state and the UI finishes its post-conversion
handoff. XCTest must wait for that terminal record as well as validating the
expected audio artifacts. In this run all chapter callbacks and artifacts were
verified, but the test host exited on the 100% label before the terminal job
record was persisted, so that persistence handoff remains unverified here.
The follow-up focused macOS XCTest
`testLocalConversionFinalizationPersistsJobAndKeepsCompleteProgressVisible`
now exercises that exact finalization path with a completed manifest and
verifies the terminal snapshot, `LibraryStore` job ID after reload, and the
100% label after the view re-renders. This closes the controller-level
handoff check without repeating the expensive live conversion.
