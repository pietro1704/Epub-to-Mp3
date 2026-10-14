# Single reader playback control

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
Pending implementation and native verification.
