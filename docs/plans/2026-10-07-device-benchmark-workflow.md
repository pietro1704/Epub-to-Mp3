# Device benchmark workflow

Implement the six retrospective findings: explicit bounded scope, one timing
report, device readiness before work, compact canonical instructions, one
reusable command, and persisted execution state for resumption.

The native Swift host orchestration owns scope validation, device identity/readiness,
signing, incremental build, staged inputs, isolated xctestrun configuration,
process identity, logs, and report aggregation. Native XCTest owns conversion,
playability, exact selected chapters, per-chunk telemetry and native timings.
No product runtime or legacy conversion behavior changes are required.

Acceptance: reject accidental full/oversized ranges before any device action;
fail locked-device preflight without building; run from immutable test plans;
report total/build/preflight/transfer/test/synthesis/verification separately;
status reads the persisted handle without polling the device; prove routing
and failure paths with host tests and native scope tests. Verify a live short
benchmark on the physical device if available. Preserve existing user changes,
serialize heavy work and publish only verified task changes when authorized.

User steering: local Python and Ruff are CI-only. Use native SwiftPM/XCTest
verification. Gitflow, commit and push are standing defaults. Also replace the
iOS 27 oversized slider thumb without reducing its accessible touch target;
verify endpoint/pressed geometry, adjacent labels and VoiceOver seek behavior.

## Verification evidence

- Native SwiftPM host workflow: 23 tests passed through the scoped preflight.
- Physical iPhone 16e, iOS 27.0.1: 21 CompactSlider/MiniPlayer layout tests
  passed, zero failures/skips. The first image-based UISlider attempt failed
  two tests on this OS; the final UIControl owns its 18-point visual and keeps
  the 44-point touch target and adjustable accessibility.
- Shell syntax, staged/working whitespace checks and the native mise status
  entry point passed. Local Python/Ruff remain delegated to CI.
- Retained one incremental Apple build tree (.build), including the small
  native host-tool cache; reports are ignored local evidence, not source data.
- Live conversion diagnostics exposed an existing Rust dependency on missing
  mobile audio tools (ffprobe/ffmpeg, OS error 2). The benchmark reports that
  failure and partial timings accurately; it is not successful audio evidence
  and this workflow/UI change does not claim to fix the conversion runtime.
