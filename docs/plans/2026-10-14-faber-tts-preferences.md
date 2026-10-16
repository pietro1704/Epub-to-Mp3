# Faber-first shared TTS selection

## Accepted scope

Implement the user's selected Piper `pt_BR-faber-medium` as the initial primary voice, optional explicitly enabled online Edge secondary, and a strict per-conversion override in all supported product clients: Rust CLI, browser/PWA and existing web shells, Flutter Android/Linux/Windows, native iOS/iPadOS/macOS. Keep the shared Rust conversion architecture. Preserve existing explicit preferences, imported books, audio, page geometry and verified Apple UI fixes.

Branch: `feature/faber-tts-preferences`, created from existing `master` and fast-forwarded to the previously verified workspace ref to preserve delivered reader/UI work. Implementation baseline: `3992c084c5`. User changes `.ai-jail` and `.ai-memory.toml` remain untouched. No PR merge, publication or CI monitoring is authorized.

## Contract and behavior

- A selection contains engine, model ID and voice. Shared Rust types define defaults, validation, language compatibility, secondary consent and resolved immutable job options.
- Initial primary: Piper/Faber. Initial secondary: none. Explicit Edge secondary requires `allow_online_fallback=true`; explicitly choosing Edge primary is itself an online selection.
- GUI preferences persist locally through platform adapters using the same serialized schema. Manual conversion can inherit preferences or replace the primary for that job; secondary use must be explicit and does not change saved defaults.
- Resolve models in Rust through the existing checksum-verified ModelStore. Missing/incompatible models yield actionable errors; never silently change a requested local voice to Edge or claim a downloaded ONNX alone is runtime-ready.
- Retry primary on each segment. Secondary handles an isolated failed segment only. Three consecutive primary failures stop the run. Cancellation never invokes secondary. Actual provider use is exposed and retained.
- Cache identity includes model/config content identity, voice, language and effective secondary/consent policy. Preserve immutable selection on resumable jobs and avoid mixing cached voices after a preference change.
- Piper and Edge segments must share valid encoded audio assembly. Publish a short first playable Piper segment, then progressively produce later audio; do not concatenate WAV and MP3 bytes.
- Browser conversion uses Rust/WASM orchestration plus a browser-local synthesis adapter (Piper ONNX/eSpeak WASM), with local model installation/storage. Browser Edge availability must be truthful and must not introduce a required external converter/server. Existing HTTP routes are legacy compatibility, not the new golden path.

## Slices and ownership

1. **Rust contract/runtime (specialist):** `crates/converter-core/{tts_preferences,worker,embedded,config,model_catalog,piper,audio,cache,jobs}`, `converter-ffi` JSON/native/JNI, `native/piper-runtime`. Add selection/fallback/cache regressions and a real offline synthesis probe.
2. **CLI (root or Rust specialist after contract):** saved preference/model commands, effective `--engine`, `--model`, `--voice`, secondary/online flags, strict overrides and executable propagation tests.
3. **Apple (specialist):** shared settings/options/FFI, native principal/secondary/model installation controls, manual override, Listen routing, native XCTest/UI regressions. If reader call sites change, apply native-reader-regression and corresponding native tests.
4. **Flutter (specialist):** persistent settings, manual and Listen options through Dart → MethodChannel/JNI or desktop FFI, capability/model management and widget/runtime regression tests. Rust owner handles JNI signatures; Flutter owner handles Kotlin callers.
5. **Web/WASM (root):** shared Rust browser orchestration/exports, local Piper synthesis adapter and model storage, preference/manual conversion UI, progressive jobs/artifacts and actual browser verification. No Rust-server detour.
6. **Packaging/verification (root, serialized):** native Piper artifacts, model phonemizer data and task definitions; one heavy job at a time under the existing lease. Review cross-client contracts before build and adversarial QA before final delivery.

## Non-goals

No new high/Pocket/Kokoro/Supertonic product integration, paid providers, voice cloning, geometry redesign, parser refactor, legacy Python implementation, book-wide automatic voice switching or implicit model downloads. No source-only claim of native performance. Downloaded test dependencies are isolated and removed after verification; intentional user-installed product voices remain.

## Risks and evidence gates

- Android currently disables Piper; verify the real ABI/platform runtime rather than removing a guard alone.
- Browser local synthesis is currently missing; ONNX inference/phonemization availability and browser Edge restrictions need an actual executable route. Show capability/install errors honestly.
- Native Piper initialization currently resets sessions and can race model selection. Reuse sessions and make model selection+synthesis atomic without blocking reader UI or running several heavy conversions together.
- Legacy clients assume Edge/default system fallback. Preserve explicitly selected Edge behavior while introducing explicit typed preferences; invalid engine values must not become online Edge.
- Language-specific Faber does not imply English support; select an explicitly configured compatible provider rather than silently narrating English in Portuguese.
- Native Apple destinations were checked before coding: exact SE1 iOS15.5 plus native macOS, using Xcode16.4. Run and exercise both; an unavailable target leaves its runtime verification incomplete.

Acceptance: typed defaults/migration/override parity; no online fallback without consent; cancellation and persistent outage boundaries; content-sensitive cache; actual provider metadata; installed/missing model flows; real native Piper synthesis and first playable segment; complete valid mixed-provider artifact; real CLI/browser/native golden paths; focused Rust/FFI/Swift/Flutter/web regression checks; final diff audit and task-specific evidence. Linux/Windows runtime limitations on this Mac must be reported rather than disguised as live verification.

## Plan review

Reviewed against the user's wording: all supported product surfaces are included, model choice is Faber medium, both primary/secondary configuration and manual selection are included, and core behavior stays Rust-owned. Discovery findings require repairing option propagation/runtime availability alongside UI; selectors alone cannot meet acceptance. The current explicit request supersedes the previous Piper suspension and Edge-primary default. Implementation may begin after specialist agreement on the serialized fields.

## Implementation review

Standards and Spec axes reviewed the owned working-tree diff against baseline
`3992c084c5`, including new files. No feature commits existed at this review;
an empty committed diff was not treated as acceptance. User changes `.ai-jail`
and `.ai-memory.toml` were excluded. Review followed `CODING_STANDARDS.md` and
this explicit plan rather than remote issues or CI monitoring.

Concrete findings and scoped corrections awaiting final execution:

- Browser audio/jobs were initially memory-only. Added committed IndexedDB
  snapshots, immutable options and completed MP3 Blobs, restore/resume without
  regenerating finished chapters, storage failure handling, and a production
  reload/full-decode regression. Temporary blob URLs are rebuilt.
- Flutter desktop initially blocked UI during parse/install and waited for a
  complete chapter before playback. Added isolated native operations, safe
  bounded Rust chunk polling and early growing audio, with responsiveness and
  first-segment regressions. Borrowed Dart callbacks are not used.
- Per-chapter Flutter calls reset the outage budget. Rust now validates and
  returns an opaque policy state; clients persist/pass it without duplicating
  fallback rules. Three separate short-chapter requests have a native regression.
- Actual Flutter model/fallback metadata was dropped. It is now retained in
  job/manifests and displayed, with a single fallback notice per job.
- Tauri file-menu uploads used remote path IDs incompatible with local jobs.
  Embedded menus now use actual HTML-selected Files; HTTP path compatibility
  remains explicit. No nonexistent native command was invented.
- Native package review found missing desktop Piper features/assets, Android
  eSpeak parent-path and ABI mismatches, and a non-relocatable CLI. Corrected
  packaging paths and minimum-OS checks; native execution remains a separate gate.

Known capability limits: browser synthesis supports installed Faber, not Edge;
the legacy HTTP server rejects typed local providers explicitly rather than
ignoring preferences. Flutter product targets are Android/Linux/Windows; Apple
products remain native Swift. Linux/Windows runtime execution is unavailable on
this Mac and must not be reported as verified.

Focused runtime, regression and packaging checks below passed; specialist final reviews found no new blockers. Source commit `bdb7bee57d` was pushed to `origin/feature/faber-tts-preferences`; no PR/merge or CI monitoring. Android device inference, Linux/Windows execution and Ubuntu CI were not run and remain explicit verification limits.

## Current acceptance evidence

Earlier passing checks do not verify source changes made after their run.

| Required surface | Evidence available | Remaining acceptance gate |
| --- | --- | --- |
| Rust selection, fallback and immutable policy | Latest focused suite passed62/62: core47, FFI4, CLI9, HTTP2, including initial actual-voice receipt regression; `checks/rust-final-audit.log` | Real CLI/macOS/SE inference separately verified below |
| CLI | Release package built/signed; relocated outside checkout with development loader/phonemizer variables removed; final refreshed package converted fresh real Faber positions0,1 in7.3445s, both MP3s fully decoded/non-silent, fallbackUsed=false; `cli-golden-evidence.json` | Complete for the Intel host path; timing excludes build and is not phone latency |
| Browser | Latest lint/173 tests/build (`checks/web-final-controls.log`) and real production synthesis, persisted reload, immutable preferences and full non-silent decode passed; `browser-production/evidence.json` | Complete for current source; phone latency is unmeasured |
| Flutter | Current analysis clean and449/449 tests passed, including worker responsiveness, cancellation, opaque policy, localized overrides and same-engine/different-voice regressions; `checks/flutter-followup.log` | Android JVM/packaging verified below; Linux/Windows execution remains unavailable |
| Native macOS | Debug build passed; real Faber streaming/final decode passed; initial13/15 passed, settings retry1passed, final actual bar/Listen/live LOTR retry3passed. Mini-player precommit refresh fixed. Latest Debug rebuild and final manual2/2 passed zero skips (`mac-final-manual-summary.json`). Earlier exact raw XCTest evidence retained | Final retry xcresult save failed (mkstemp); raw stdout proves execution. Cached-display screenshots omit native control text; do not treat them as visual rendering proof |
| Native iOS | Exact SE1/iOS15.5:17 prepared scenarios passed across initial15, full preferences/manual UI retry and real Faber retry1passed0skipped. Reader probes passed; Faber first segment precedes completion and both chapters fully decode. Stale eSpeak path buffer fixed/verified1024bytes. Structured evidence under `se-*-summary.json` | Final Simulator/device artifacts refreshed; final manual2/2 and real LOTR1/1 passed zero skips (`se-final-manual-summary.json`, `se-final-reader-summary.json`). No physical device runtime claim |
| Android | Focused Flutter74/74 and JVM17/17 passed with zero skips (`checks/android-final-tests.log`, `android-jvm-final/`); immutable payload/cancellation regressions included | ARM64 build, ELF/exports/assets package and debug APK passed; APK native entries checked (`android-apk-final.json`). Fresh-checkout missing-assets rejection and official automatic restoration/APK audit passed (`android-missing-assets-evidence.json`, `checks/android-fresh-assets-arm64-rebuild.log`); APK is ARM64-only. Android device inference and Ubuntu CI were not run |
| Flutter Linux/Windows | Shared CMake staging fixture passed | Source/test coverage and packaging checks on this Mac; actual target execution is unavailable and must remain explicitly unverified |
| Delivery | Local preflight and whitespace checks passed | Final owned diff reviewed;12 owned temporary paths cleaned (`owned-test-cleanup.json`); source commit `bdb7bee57d` pushed to origin; no PR/merge or CI monitoring |

Native runtime correction: the user questioned the full ONNX source build.
It was stopped with completed objects preserved. The default host task now
installs the checksum-pinned Sherpa-maintainer ONNX Runtime 1.28.2 artifact;
actual Intel Mach-O inspection proves x86_64 and minimum macOS 10.15. The
source builder remains an explicitly invoked fallback. Piper's existing Rust
adapter and original catalog weights are retained; no Sherpa model conversion
or Python runtime is introduced. Apple Silicon artifact metadata was inspected
separately: ARM64 artifact minimum macOS11.0 and
checksum verified. Intel runtime is installed. Actual inference remains a
separate acceptance gate; no Apple Silicon execution is claimed.
