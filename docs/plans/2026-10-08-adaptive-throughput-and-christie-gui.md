# Adaptive TTS throughput and full macOS conversion

## Scope

- Add provider-neutral per-conversion throughput feedback; Edge reports chunk
  latency, characters/second, retries, timeout, and explicit throttling.
- Start from the measured 4k/two-request profile, adapt request size and
  concurrency conservatively, and preserve audio order.
- Persist chunk metrics in the Rust conversion log and retain provider-neutral
  policy tests plus Edge adapter classification tests.
- Clear rebuildable application caches, then invoke the macOS detail screen's
  manual Convert action for the full imported “E não sobrou nenhum” EPUB.

## Non-goals

- Do not use Python/backend conversion or change the Apple runtime boundary.
- Do not delete imported EPUBs, manifests, completed audio, models, or job history.
- Do not run the full LOTR book or monitor CI/PRs.

## Acceptance evidence

- Deterministic tests cover initial tuning, success-based growth, slow-response
  reduction, throttle cooldown, and a provider-neutral caller contract.
- Rust and macOS integration tests pass; the app embeds the freshly built
  architecture/ABI-verified Rust FFI artifact.
- A real GUI click starts a manual full-book conversion, visible progress and
  per-chunk metrics advance, terminal state is completed, manifest chapter
  coverage matches the imported EPUB, and every MP3 passes `ffprobe`.
- Application rebuildable caches are absent after the run; user audio and
  manifests remain present.
