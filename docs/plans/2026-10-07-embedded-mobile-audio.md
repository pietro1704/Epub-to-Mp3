# Embedded mobile audio

Repair the native Rust conversion failure reproduced on iPhone:
`audio error: I/O error: No such file or directory (os error 2)` after TTS
finishes, before validated chapter publication. The worker invokes ffprobe for
validation and ffmpeg for cover embedding; iOS cannot supply these processes.

Replace duration/sample-rate inspection with in-process MP3/WAV demuxing and
write MP3 cover metadata losslessly in Rust. Use the same implementation on all
embedded surfaces, independent of provider/model. Preserve validation, existing
tags, compressed audio bytes, atomic replacement, cancellation and chapter order.
Desktop-only editing helpers are outside the exercised conversion path and must
not be silently selected by mobile conversion.

Acceptance: isolated Rust tests pass with unavailable external tools; invalid,
empty and truncated audio is rejected; MP3 audio payload and duration are
unchanged by repeated cover writes; existing WAV worker fixtures still validate.
Rebuild/verify the iOS FFI and signed XCTest host, then run 1–2 explicit chapters
from each of LOTR/Christie on the physical iPhone. Require terminal completion,
playable MP3s and persisted timing/provider/cache evidence. No whole-book run,
local Python/Ruff or CI/PR monitoring. Commit/push using Gitflow after verification.

## Evidence and remaining gates

- Final isolated no-external-process audio suite: 10 tests passed, including
  explicit Info/Xing whole-frame truncation and binary midstream ID3 bodies.
  The scanner feeds only bounded, real MPEG frames to the decoder, validates
  declared counts per independent segment, and preserves joined duration.
  Core library suite: 69 tests passed after the final segment changes.
- The arm64 iOS FFI rebuild completed and passed architecture/platform/ABI
  checks. Native device installation and execution remain separate gates.
- Native host workflow: 25 tests passed. Temporary schema-v2 input/report
  paths avoid service-owned Application Support directories without modifying
  production storage or user books.
- Device run F6EBC39D-B4A5-45F5-9DDE-2060F7C055FB launched XCTest but failed
  during metadata preflight, before synthesis: `Unsafe output directory.`
  A deterministic Foundation reproduction showed missing-directory URL
  resolution drops the directory hint. Filesystem-path comparison accepts
  missing parents while retaining symlink rejection; the isolated Foundation
  check passed and a permanent native regression was added.
- Native XCTest of the final harness and the four requested chapters remain
  pending: the next readiness check found the iPhone locked. No conversion
  success, speed improvement, or final delivery is claimed from these checks.

## Review

Reviewed the owned working diff against base `0effe3a52f`, this plan, and
`CODING_STANDARDS.md`. Shared audio processing stays in Rust; covers preserve
compressed bytes and existing tags, and their decoding is bounded and reused.
Adversarial findings about joined-stream duration, explicit segment counts,
partial frames and binary ID3 sync search have regression coverage.
No CI/PR audit, Python/Ruff execution, simulator or product storage change is
included. Device acceptance is incomplete, not waived: final native XCTest,
terminal completion and playability for LOTR 8–9 / Christie 6–7 are required.
