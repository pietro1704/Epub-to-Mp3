# Reader page playback choice

> **Historical record (reviewed 2026-10-21).** The separate current-page button is superseded by the [single reader playback control decision](2026-10-14-single-playback-control.md). Preserve the original red/green and timing evidence; session-specific no-PR and leave-open boundaries are historical. Use [execution policy](../agents/execution-policy.md) for current scope, guarded builds and Simulator quarantine, and [runtime navigation](../agents/runtime-navigation.md) for architecture; old commands and authorizations are retained only as evidence.

## Scope and acceptance

Keep audio and reader navigation independent until the listener explicitly
chooses to play the newly visible page. While audio plays, expose a clearly
named current-page action without replacing Pause. After reader movement,
paused Play offers playing the current page or continuing the existing cursor.
Unchanged-page pause/resume retains the existing queue/cursor. Same-chapter
page turns and streaming queues must behave consistently on iOS and macOS.

Preserve verified reader geometry, providers, downloads, conversion lifecycle
and system transport. Existing sentence timing is preferred; proportional
chapter timing remains the existing fallback when exact timing is unavailable.

## Execution

1. Commit/push previously verified work and required new runtime files;
   preserve local harness configuration. Integrate current master before push.
2. Reproduce the paused-page change through actual UIKit Play handling with
   valid local audio. Test at existing AudioPlayer/reader transport and native
   UI seams authorized by the user's requested app verification.
3. Make the smallest routing and current-page control change. Add focused
   coverage for choosing current page, continuing audio, unchanged-page resume,
   and streaming without rebuilding a URL-less snapshot.
4. Exercise exact SE/iOS15.5 and macOS, audit against this plan and standards,
   restore original reader state and leave only the normal SE app open.
5. Commit/push the verified correction. No PR/CI monitoring or merge requested.

## Prior delivery

Prior runtime fixes committed as `c30ae5a7e0`. Current master integration only
changes CI/Python/web dependencies, without touching verified Apple/Rust code.

## Diagnosis and focused evidence

- Prior feature branch pushed successfully with `c30ae5a7e0` and master
  integration `8c5267535e`; read-only preflight passed. Local `.ai-jail` and
  `.ai-memory.toml` were preserved outside commits.
- UIKit paused-page regression failed in 1.344 s: Play resumed instead of
  presenting a choice (`/tmp/reader-page-choice-red.log`). Removing the
  unconditional paused-queue bypass and tracking the acknowledged reader
  location passed 63 native tests (`/tmp/reader-page-choice-green.log`).
- Review exposed an initially unknown streaming duration losing the chosen
  page ratio. Native regression failed at actual position 0 instead of 7.5 s
  (`/tmp/reader-page-streaming-duration-red.log`). Keep the ratio on the pending
  navigation rather than on a current-item cursor, then resolve it against the
  target chapter's complete duration or explicit total estimate. Preserve it
  through final-file handoff. The actual production updateSnapshot path plus
  four UIKit choice/unchanged-page/book-identity tests passed 5/5 in
  `/tmp/reader-page-choice-long-gui.log`.
- GUI setup corrections: initial short fixture fitted one page, so use a
  two-chapter fixture long enough for actual page turns. Select the choice
  inside its sheet to distinguish it from the toolbar's identically named
  accessible action. Exercise real horizontal swipes and local Edge MP3s.
- Gate current-page actions by the live playback's reader-book identity or
  the book's retained conversion job. Never apply another book's coordinates
  to the current audio snapshot. UIKit already proves cross-book safety.

## Final verification

- Exact iPhone SE (1st generation), iOS15.5, Xcode16.4: 68/68 native tests
  and 2/2 actual GUI tests passed. Real Edge playback exercised page choice,
  continuing the existing cursor, current-page action while playing, and
  ordinary unchanged-page pause/resume. Actual LOTR pagination/chrome passed.
  Log: /tmp/reader-page-choice-final-se.log; attachments:
  /tmp/reader-page-choice-final-attachments.
- The actual long-page GUI reproduced scroll ratio 1 incorrectly seeking the
  audio end. Audio anchors now use first-visible character / UTF16 text length;
  saved reader scroll progress and layout geometry are unchanged.
- macOS: 64/64 focused native tests passed in actual runtime stdout
  (/tmp/reader-page-choice-mac64-runtime.log). Xcode failed saving that result
  bundle, so the raw log is the evidence for this run. Final exact-source
  native window/button/sheet and streaming handoff tests passed 3/3 with a
  valid result summary (/tmp/reader-page-choice-mac-book-state-summary.json).
- Review findings addressed: unknown-duration streaming ratio retention,
  cross-book seek safety, and stale Mac current-page control enabled state.
  The last issue was reproduced red and verified green in native controls.
- Original reading preferences and LOTR seed restored; only the two owned
  verification books/artifacts archived reversibly under
  /tmp/reader-page-choice-artifacts. The normal SE app is left open.
- No provider policy, downloads, remote transport or reader geometry changes.
  Without sentence timing, page playback uses proportional text/chapter timing,
  not an exact word timestamp. Physical phones and CI were not exercised.

Delivery: correction b0186420eb committed and pushed successfully on
fix/reader-page-playback-choice. Normal SE app PID 91535; screenshot:
/tmp/reader-page-choice-final-normal-app.png. Prior work was pushed on
feature/native-tts-fallback at 8c5267535e, including c30ae5a7e0.

Postmortem: exercise pause preservation together with real page turns using
a long enough fixture; scope sheet selectors and disable test-only overlays.
