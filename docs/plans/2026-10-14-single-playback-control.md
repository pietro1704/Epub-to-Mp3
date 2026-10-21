# Single reader playback control

> **Historical record (reviewed 2026-10-21).** Retained product decision and bounded native evidence. This supersedes the [separate-button plan](2026-10-14-reader-page-playback-choice.md); Simulator/leave-open/no-PR execution details describe that session. Use [execution policy](../agents/execution-policy.md) for current scope, guarded builds and Simulator quarantine, and [runtime navigation](../agents/runtime-navigation.md) for architecture; old commands and authorizations are retained only as evidence.

## Scope
User approved removing the separate current-page button, which is too small
on the SE. Keep the existing large Play/Pause control. While playing, tapping
it only pauses. When the visible reader page has moved, the next Play opens
two full-width native choices: Continue where I left off / Listen from this
page, plus Cancel. With no page movement, resume immediately.

This supersedes the separate-button requirement in the previous page-choice
plan. No changes to AudioPlayer state, streaming seek, providers, downloads,
reader layout, pagination or geometry.

## Files and risks
Remove iOS reader navbar action and its subscription; remove Mac player-bar
action/callback/subscriptions. Keep the Mac page-seek helper for the chooser.
Use existing UIKit action sheet and NSAlert with Continue first. Update
English, Portuguese and Spanish labels. Update native and GUI regression tests.
Risks: wrong Mac alert response mapping after reorder; repeated prompting;
cancel changing cursor; long labels clipping on the 320-point SE.

## Inspection review
Independent state, UI and runtime passes confirm existing playTapDecision
already implements Pause then Play, including same-page resume. Native action
sheets provide large system touch targets; no custom presentation is needed.

## Acceptance evidence
Run native choice tests on exact iPhone SE/iOS15.5 and macOS, actual Edge GUI
choice flow and seeded LOTR reader geometry check. Assert removed action absent,
two choices plus Cancel, Pause without prompt, Cancel keeps cursor, Continue
keeps cursor, current-page seek works, unchanged-page resume has no prompt.
Capture the actual SE sheet with full Portuguese labels and final normal app.
Preserve original preferences/book and leave only normal SE app open.
Commit/push focused correction after diff review and preflight.

## Results
- Red regression: actual Mac player-bar test rejected the separate action
  (exit 65, 1 passed/1 failed): /tmp/single-playback-mac-red.log.
- macOS: 21/21 focused native tests passed, including real window/button/sheet
  actions, Continue, Cancel preserving cursor, and unchanged-page resume.
  Command: Xcode16.4 + APPLE_NATIVE_TESTS selecting MacReaderPagePlaybackChoiceTests
  and AudioPlayerDivergenceTests via mise run apple:chapter-callback:test.
  Evidence: /tmp/single-playback-mac-summary.json.
- Exact SE/iOS15.5/Xcode16.4: 23/23 native tests and 2/2 actual GUI tests passed
  through mise run ios:simulator:test, explicit SE UDID, APP_IOS_LIVE_EDGE=1,
  dedicated long fixture ID and selected choice/divergence/GUI test classes.
  Actual Edge audio, page turns, Continue/current-page seek, Pause, Cancel and
  ordinary resume exercised. /tmp/single-playback-se.log and summary.json.
- Portuguese full labels fit on the 320-point screen; both choices and Cancel
  have at least 44-point touch height. Screenshot inspected:
  /tmp/single-playback-se-attachments/CFF97393-3284-4043-84A7-041CB1EE8391.png.
- Actual seeded LOTR pagination/chrome passed 1/1 (23.048 s), reusing the same
  build with IOS_SKIP_BUILD=1. /tmp/single-playback-lotr.log and attachments.
- Independent adversarial diff audit found no concrete blocker. Mac reordered
  response mapping, cancellation and removals reviewed. Whitespace/preflight
  passed. No AudioPlayer, providers, downloads or viewport geometry changes.
- Original reader preferences and LOTR seed restored. Only the owned fixture
  archived reversibly at /tmp/single-playback-fixture-archive. Normal SE app
  left open (PID 95539); no Mac app/other Simulator running.
  Final screenshot: /tmp/single-playback-final-normal-app.png.
- Physical phones, CI and new performance benchmarks not run. Proportional
  text/chapter timing remains when sentence timing is unavailable.
- Delivered: c3249a17 committed and pushed on fix/single-reader-playback-control.
  No PR, merge or CI monitoring requested.
