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
