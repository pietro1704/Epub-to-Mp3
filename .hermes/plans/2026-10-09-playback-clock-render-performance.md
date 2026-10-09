# Playback clock render performance

## Goal

Keep 250 ms playback clock updates limited to progress controls in the mini
player and the iOS player screens. Preserve full state rendering for title,
chapter, playback commands, menus, artwork, library, and presentation changes.

## User preference

Pietro prefers the oldest compatible technology and runtime for performance.
Use the target's existing UIKit/AppKit implementation where it fits, and use
profiles to establish performance rather than treating age as proof.

## Scope

- MiniPlayerBarHost
- PlayerScreenController
- FullPlayerScreenController
- Focused native regression tests beside these production files
- TODO_APP.md completion evidence

Do not rewrite frameworks, replace Combine, change compiler flags, or alter
playback timing. Do not expand into reader or Rust performance.

## Acceptance

- A playback clock tick updates displayed progress on all three iOS surfaces.
- A playback clock tick does not run structural player rendering or recreate
  artwork, menus, title/chapter state, or other non-progress controls.
- Structural updates still refresh the affected player controls.
- The iOS app is built, launched, and the playback behavior exercised on
  iPhone SE (1st generation) Simulator with iOS 15.5.
- The native macOS app is built, launched, and its corresponding playback
  behavior exercised.
- Run focused native tests and record exact results.
- Capture comparable before/after performance evidence where the simulator and
  macOS runtime permit it. State when Simulator evidence cannot represent
  physical iPhone performance.
- Review the final diff, commit verified files, push, and leave the checkout on
  master.

## Investigation

The playback clock is an isolated ObservableObject published by AudioPlayer
every 250 ms. Its consumers currently subscribe that event to render() in all
three iOS surfaces. FullPlayerScreenController also listens to player.position
and refreshes the progress controls separately. Full render methods perform
title/library/artwork/menu work alongside progress.

## Progress

- [x] Confirmed repository instructions, branch/status, native schemes, and
  exact iOS 15.5 iPhone SE (1st generation) Simulator availability.
- [x] Baseline code inspection found structural rendering on every 250 ms
  tick; no Instruments baseline was captured, so no numeric speedup is claimed.
- [x] Added focused XCTest coverage first. It failed because the rate menus
  were rebuilt on clock ticks, then passed after separating clock progress
  rendering from structural state rendering.
- [x] Focused native tests: `PlayerPlaybackClockTests`, 3 passed, 0 failed on
  iPhone SE (1st generation) Simulator / iOS 15.5 with Xcode 16.4.
- [x] Installed, launched, and inspected the iOS app on the requested Simulator.
  The LOTR reading screen showed the mini player and progress controls; the
  process remained active. (The requested iOS app artifact was built as part of
  the focused test build.)
- [x] Built the native AppKit target with Xcode 16.4 and opened it successfully.
  The standard `mise run mac:run` was blocked before Xcode by unrelated Rust
  compile errors in `converter-core/src/worker.rs` (missing `source_index` and
  two required `synthesize_with_reference_client` arguments). The desktop app
  launched, but there was no active playback session to exercise a clock tick.
- [x] Reviewed the scoped diff and `git diff --check`. Keep Combine and UIKit;
  source and test evidence support narrowing subscribers, not replacing the
  framework or compiler settings. No comparable Instruments profile was taken,
  so quantitative performance remains unmeasured.
- [ ] Verify the active playback tick in the native macOS app. The app built
  and launched, but no playback session was active; the repository's `mise`
  launcher is independently blocked by Rust pre-build compile errors.
- [ ] Commit and push the scoped changes to `master`; preserve unrelated edits.
