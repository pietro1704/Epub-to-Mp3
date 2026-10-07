# macOS Rust audio delivery

## Objective

Make macOS Listen stream locally synthesized Rust audio into the native player
as validated Edge chunks arrive, while manual Convert uses the same Rust
pipeline to create the complete book without autoplay or an indefinite wait.
Verify playback and conversion against the seeded Lord of the Rings EPUB.

## Vertical slices

1. Rust worker and C ABI expose conversion progress plus ordered chapter
   completion only after each complete MP3 passes `ffprobe`, preserving the
   original EPUB position in partial manifests. Add deterministic Rust tests
   for validation, ordering, and positional-vs-TOC selector collisions.
2. Swift adapter/coordinator deliver those chunks to `AudioPlayer`; macOS
   Listen arms autoplay and manual Convert does not. Add native tests for both
   routes and terminal/error state.
3. Build and launch the macOS app, exercise Listen and Convert with the seeded
   Lord of the Rings EPUB, verify generated audio with AVFoundation/ffprobe,
   confirm visible progress and terminal completion, and audit the diff.

## Scope and constraints

- Keep Rust as the only conversion runtime; no Python, HTTP, or sidecar.
- Preserve the caller's existing Swift edits and chapter-selection behavior.
- Listen begins at the reader's saved EPUB position and continues through the
  remaining chapters in EPUB order; Listen remains serial to preserve arrival
  order in the live player queue. Manual full-book conversion uses at most two
  concurrent chapter workers on Apple platforms.
- Conversion logs include wall-clock timestamps, elapsed time, inter-event
  gaps, and per-chapter synthesis throughput. An opt-in live Edge benchmark
  compares serial and two-worker conversion on the same LOTR chapters.
- Manual conversion must never autoplay; failures/timeouts must become visible.
- Do not change iOS reader layout or simulator behavior.

## Acceptance evidence

- Rust unit tests prove emitted chapters are ordered and published only after
  full-file audio validation; failures terminate instead of hanging.
- macOS XCTest proves Listen starts on first chunk and Convert stays paused.
- Real LOTR macOS run proves first audible audio arrives before book completion,
  full conversion completes without a stuck state, and final MP3 artifacts pass
  AVFoundation readiness plus `ffprobe` duration checks.
- The opt-in Rust Edge benchmark records validated output and measured
  serial-versus-two-worker wall times; parallelism is retained only if it
  improves throughput without affecting Listen ordering.
