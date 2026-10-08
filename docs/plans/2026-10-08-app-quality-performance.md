# App quality and performance

Scope: repair every finding from the native app audit, in independently tested
and committed slices on `fix/app-quality-performance`, based on local develop
including verified embedded-audio prerequisites (`0d3a8229`). No remote merges.

## Ordered acceptance checklist

1. Durable library import: failed replacement preserves prior bytes and its
   bookmark target; same-file reimport is harmless; successful replacement is
   atomic. Native tests exercise the existing durable-import boundary.
2. Chapter scope: reject invalid nonempty selections before Rust/device work;
   support explicit single chapters and inclusive ranges; whole-book selection
   is intentional, never an error fallback.
3. Conversion configuration: provider/model/voice/language and supported flags
   reach Rust through a versioned FFI contract; unsupported choices fail clearly.
   Manual conversion must not change playback or autoplay. Native and Rust
   tests exercise configuration routing and reject silent defaults.
4. Segment playback: chapter-relative seek selects the right segment/local time;
   next chapter works when available only in the backlog and retains pending
   navigation when not yet available. Native player regressions required.
5. Adaptive TTS: size changes affect unsent work in the same chapter, preserve
   text/audio ordering, and honor request concurrency/cancellation. Controlled
   transport tests prove behavior; physical benchmarks measure the result.
6. Main-thread work: batch import/hash/copy/metadata, segment audio persistence,
   and history loading leave the interaction thread. Bound history reads and
   avoid repeated full-library persistence during a batch. Test preservation,
   queue ordering and responsiveness at real public boundaries.
7. Performance evidence: measure book-open, first audible audio, seek/navigation,
   memory and relevant IO costs before/after. Warm-open target is 200 ms; a
   telemetry-emission test alone cannot establish the budget. Record missing
   measurements explicitly rather than declaring targets achieved.

## Verification and constraints

Use actual mise tasks and focused native XCTest/Rust tests. Serialize heavy
work with the existing lease, prefer the physical iPhone, terminate the previous
app before runs, and reuse the single incremental build cache. No local Python,
Ruff, osascript, Simulator, CI/PR monitoring, model downloads or user-data cleanup.
Fixture directories are exclusively owned and disposable; books, models and
offline listening downloads are preserved. Commit/push only verified slices.

Conversion baseline: physical iPhone 16e / iOS 27.0.1, run
`8EB8510F-B673-4804-BBA8-CFD53D0A24ED`, commit `0d3a8229` runtime lineage,
LOTR source hash `3e1c676b270dfa3fe555eba4d0cb993486e9f00facb7cc92eef250e64efb7c9e`
chapters 8–9, Christie hash
`55417053355de78768a0823d3cd203fde5c80bd8026407ffb5766b3f730d11da` chapters 6–7.
Synthesis: 310.397 s / 6.339 s, no audio reuse. Reuse these exact inputs/ranges
for comparison, at most two chapters per book. Network variation and missing
memory baseline must be accounted for; do not infer a causal speedup from one
uncontrolled comparison or extrapolate whole-book duration.

## Progress

### Slice 1 — durable import safety

Implemented: copy into an exclusively reserved same-volume staging directory;
replace only after the copy succeeds; same-file reimport is a no-op; cleanup
targets only that staging directory. No existing book is removed before copy.

Red: physical iPhone run `49ED0837-4B37-4DBF-9ADB-E904C77CA953` failed the
new preservation regression: the prior `Book.epub` was missing after simulated
copy failure (Cocoa 260). Final green:
`EAF9072B-CF91-43BE-A74D-D6AE92C9EE41`, four focused native tests passed,
zero failures/skips, 22.93 s total (13.11 s incremental build, 7.16 s tests).
Tests cover partial-copy and final-replacement failures, source/previous bytes,
staging cleanup, self-reimport, successful replacement with an old bookmark,
and the existing original-removal survival case. Only disposable fixtures were
created and removed; no user books/models/downloads were targeted.

Review against base `0d3a8229`, this plan and coding standards: the original
delete-before-copy cause is removed; two-axis inspection and specialist QA
requested replacement/bookmark and partial-copy evidence, which now passes.
An initial attempt to override the Swift replacement convenience did not compile;
the regression uses the corresponding overridable Foundation method instead.
`git diff --check` passed. No Mac UI or crash/power-loss durability claim is made.

Item 1 is verified on the physical iPhone. Items 2–7 remain pending.
