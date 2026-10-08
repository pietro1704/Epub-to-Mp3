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

### Slice 2 — chapter selection (in progress)

The existing form parser has been extracted without changing its behavior so
the exact production boundary is reachable by native tests. A regression now
requires rejection of malformed/reversed/overflowing selections, single-chapter
support and explicit empty-field whole-book selection. The first test attempt
`EB930396-C4D2-46D6-AB40-3BD390C6DFBF` stopped at locked-device readiness;
it did not compile or execute the regression. No parser fix or completion is
claimed yet. Broader Swift/FFI sentinel consistency remains part of this item.

Rust FFI boundary: the new regression reproduced acceptance of invalid
`-2..-1` as whole-book selection. Validation now rejects mixed/invalid negative
sentinels, reversed and out-of-bounds indices before allocation or output
directory creation in both existing conversion ABIs. Explicit `-1,-1` whole-book
and legacy nonnegative-start / `-1` to-end selection remain supported. A huge
end bound is rejected before allocating positional selectors.
`cargo test -p converter-ffi --lib --jobs 1` through mise and the native heavy
lease passed 12 tests, zero failures, in 0.01 s (6.29 s incremental compilation
after the cold dependency rebuild). Two public ABI regressions verify early
rejection without touching their output fixture; a regular-file destination
prevents any network synthesis even if that validation regresses.

Review: the Rust-only guard is verified on the host. C ABI signatures are
unchanged and successful explicit selection semantics are retained. Device
FFI embedding, form behavior and Swift to-end range reconciliation remain
pending; item 2 is not complete from this host evidence alone.
Specialist QA found no blocking Rust guard issue and requested a multi-chapter
fixture. The final 12-test run adds a three-chapter EPUB, verifies `1..2` and
`1..-1`, and rejects `1..0` with a valid start. Final compilation was 3.99 s;
evidence is `.reports/mobile-audio/quality-ffi-selection.log`. Rustfmt and
working/staged whitespace checks pass. Only the guard and this evidence are
included in its commit; native-form and adaptive-TTS changes remain separate.

Independent Rust chunk-adaptation work may proceed while native readiness is
blocked; ownership excludes the main agent's Swift files and no online synthesis
is authorized beyond the prescribed comparison samples.

### Slice 3a — reject unsupported provider configuration

Red: the core selector accepted requested `coqui` as Edge in
`unsupported_engine_configuration_never_silently_selects_edge` (0.00 s test).
It now returns an explicit `UnsupportedEngine` error for unsupported requested
or configured values instead of silently changing providers. Edge, Piper,
case/whitespace normalization and existing auto-to-Edge behavior are preserved.
This is only the core guard; UI/FFI options forwarding, runtime/model readiness,
flags and manual-conversion playback intent are still pending (item 3 partial).

Final serialized verification through mise: 70 core library tests, seven
pending-adaptation integration tests, and 12 FFI tests passed. Evidence:
`.reports/mobile-audio/quality-core-guards-and-adaptation.log`. No model download,
external TTS request or user-artifact mutation was involved.

### Slice 5a — dynamic pending chunks (host verified)

Pending fragments are selected after acquiring current capacity, using the
latest size limit. Retry fallback subfragments also honor subsequent reductions
and make strict recursive progress. Feedback is published before permits are
released, preventing waiters from seeing capacity before the pressure update.
Blank fragments are consumed without speech requests or audio indices; spoken
content, UTF-8 and audio order are retained. Chunk totals in telemetry are now
estimates while adaptation is active, not a fixed progress denominator.

Controlled local protocol regressions reproduced stale chunks after a size
reduction, stale retry subfragments after repeated 429s, and feedback after permit
release. Seven integration tests now cover those cases, whitespace-only request
avoidance, capacity growth/out-of-order completion, retry recovery and dropping
an active synthesis. Existing protocol tests also pass in the 70-test core suite.

Specialist final QA found no blocking issue; additional shared-controller shrink
and cancellation-during-cooldown stress coverage is not yet performed. This
verifies dispatch behavior, not full native cancellation or a speedup. Physical
FFI rebuild/embedding and exact-book before/after measurements remain required
for item 5 and all latency/memory acceptance gates.

### Slice 6a — bounded, asynchronous conversion-history reads

The Mac history controller now calls an asynchronous Foundation reader rather
than reading/ splitting the entire log on the main thread. The reader scans
16 KiB blocks backwards, selects the latest nonempty records, and enforces a
1 MiB byte budget. Partial leading records are discarded before UTF-8 JSON
decoding; malformed or unfinished records do not discard valid recent rows.
Cancellation is checked before IO, between reads and around decode. Refreshes
cancel prior work and discard results from stale generations; UI updates remain
on MainActor. A localized read-limit message distinguishes oversized history.

The lightweight `apple:foundation:test` task compiles the actual production
reader and DTO alongside native XCTest, without an app, Simulator or device.
Its SwiftPM scratch directory is nested inside the single `.build` tree and
the task holds the same native heavy-job lease. Seven tests passed, including
IO outside main, cancellation before opening, UTF-8/CRLF, oversized records,
zero-read limits and trailing blank-line compatibility. Specialist QA caught
the initial LF-only counting regression; its new native test failed before
counting nonempty records and passed after correction.

Controlled local measurement, identical synthetic 10,000-record content:
8,407,780 bytes / 2,628.59 ms before versus 98,304 bytes / 6.94 ms after, with
the same latest 100 records. Logs: `.reports/mobile-audio/history-before.log`
and `history-final.log`. These are single Debug service observations, not a
production-app speedup ratio or resident-memory measurement.
The four real Mac controller/reader/model/localization files also passed
`swiftc -typecheck -swift-version 5 -strict-concurrency=complete` for macOS 12.
Working/staged diff checks passed. No UI process was launched or user log changed.

Limits: full AppKit screen responsiveness/reload integration is not yet exercised;
the controller retains its legacy-compatible local log source (a native-history
producer was not added). Batch import, audio persistence and whole-app
latency/memory gates remain pending. This slice does not complete items 6–7.

### Slice 2b — fail-closed form chapter selection

The form uses the shared production `ConversionChapterSelection` parser, also
compiled unchanged by the native Foundation test target. Only an empty trimmed
field selects `(-1,-1)` whole-book conversion; a single nonnegative ASCII Int32
selects exactly itself, and an inclusive ordered range preserves its indices.
Malformed, empty-component, negative, overflowing and extra-component inputs
throw instead of being compacted or falling back to whole-book selection.
The view model localizes that error before security-scoped access or conversion.

Red: three native parser tests produced 13 failed assertions, reproducing invalid
inputs and single indices silently becoming whole-book selection. Final green:
`mise run apple:foundation:test` passed all 10 tests (three parser, seven history),
including Int32 maximum, overflow on either endpoint, same-index ranges, plus
signs, Unicode digits and decimal values. Logs are
`.reports/mobile-audio/chapter-selection-red.log` and `chapter-selection-green.log`.
Specialist review found no blocker; requested edge coverage was added. Working
and staged whitespace checks passed; literals/locales were preserved.

This verifies the form's production parsing boundary on the native host, not its
full UIKit integration. The matching view-model XCTest is checked in but has not
run since the locked-device preflight. Swift coordinator / FFI start-to-end
sentinel consistency and native embedding remain pending, so item 2 stays partial.
