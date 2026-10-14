# iPhone SE streaming, downloads and transport goal

## Scope

Actual iPhone SE (1st generation), iOS 15.5, Xcode 16.4. Verify fresh Edge audio
starts promptly before conversion completion; pause/resume, next/previous,
seek controls and retained two-chapter downloads/local replay. Exercise the app
first, record observed errors, then plan and implement minimal corrections.

## Boundaries

Preserve existing working app flows, imported books/audio and dirty changes.
Piper remains suspended; native speech only isolated fallback. No speculative
provider swaps, reader redesign, physical-device action or CI monitoring.
Serialize native work with existing guard; leave only exact SE app open.

## Initial verification plan

1. Inspect contract/UI/runtime in independent specialist passes.
2. Reuse prepared unique two-chapter EPUB; build focused native/UI tests with
   Xcode 16.4 and actual bundled Rust FFI. Stage fixture in SE and run GUI first.
3. Record actual failures separately from test harness defects. Write correction
   plan against observed evidence before production edits.
4. Apply minimal fixes with permanent native regressions, rerun actual GUI and
   Edge/download/transport checks. Verify Mac parity if shared behavior changes.
5. Audit scoped diff, preserve existing seeded LOTR and finish with SE app open.

## Initial error list and correction plan

Initial actual SE execution completed before production edits.

1. Download failure: manual Edge conversion creates MP3/ZIP, but
   DownloadManager cannot resolve Rust's absolute filesystem audio paths.
   `testOptInLiveEdgeManualConvertCreatesAudioWithoutAutoplay` fails retaining
   audio and rebuilding the local snapshot. Fix local-path resolution while
   preserving remote-root-relative URL semantics; lock down literal filename
   characters and actual persisted MP3 replay.
2. Streaming next control: GUI streaming starts, pauses correctly, but tapping
   Next does not select the second chapter within 20 seconds. The live reader
   publishes only completed chapter headers, leaving upcoming chapters absent
   from the player's navigation catalog. Populate pending chapter metadata from
   the reader catalog and preserve it during completion updates; verify pending
   next/previous and autoplay intent with permanent native regression plus GUI.
3. Edge fallback/performance: actual two-chapter transport starts in 2.254 s and
   passes controls, but finishes in 52.395 s with system speech used. Diagnose
   exact timeout/transport/MP3 reason before changing provider budgets. Keep Edge
   primary and first-audio latency bounded; retain isolated native fallback.
4. Harness defect, corrected: GUI looked for the removed mainReader Listen
   button. Use existing mini-player Play and Open, preserving current app flow.

Initial evidence: `/tmp/se-streaming-initial-native.log` (3 tests, 2 failed),
`/tmp/se-streaming-initial-ui2.log` (1 actual GUI test failed at Next), and
`/tmp/se-streaming-ui2-attachments` (screenshots/accessibility hierarchy).

## Correction order and acceptance

Fix local download resolution, then pending chapter navigation; probe unexpected
Edge fallback and make only evidence-backed timing changes. Add regression for
paused navigation of downloaded chapters before deciding whether that separate
suspected defect needs a fix. Extend actual GUI coverage to skip/seek/rate and
local replay after relaunch. Run focused Rust/native tests, exact SE GUI and Mac
parity for shared behavior changes; record every newly observed error here.

## Additional reproduced findings

- Download resolver regressions pass 11/11 after the fix. MP3 persistence and
  positive AVFoundation duration now pass. Local playback assertion still failed
  because the new test did not explicitly resume the newly installed queue;
  correct the harness to perform the listener's Play action.
- `AudioPlayerNavigationPauseTests` reproduces a separate app bug: Previous on a
  downloaded chapter restores an old playing marker and resumes despite the
  current explicit pause. Preserve live autoplay intent across chapter queue
  replacement and full-file streaming handoff, ignoring stale marker autoplay.
  Rerun this permanent regression on SE and Mac.
- The existing pending-seek suite reproduced a missing loading signal in 13
  scenarios (15 assertions): a target waiting for audio was not reported as
  loading. Include pending seeks in loading state, while keeping the mini-player
  transport available so the listener can pause/resume during that wait.
- Actual GUI download copied the MP3 and saved its manifest, but the open chapter
  list never refreshed its download badge. The existing local-artifact observer
  is disabled after the runtime migration. Observe the active DownloadManager
  progress stream for this job and refresh terminal state; verify immediate UI
  feedback with a permanent native test and actual GUI.
- Reopening with only chapter zero explicitly retained restored a one-chapter
  download snapshot and hid the already-converted second chapter. Actual GUI
  Next failed again despite its valid full conversion manifest. Restore usable
  completed Rust artifacts together with retained downloads; prefer protected
  downloaded URLs and retain all available chapter identities. Cover partial
  download restoration natively and verify next/previous after relaunch in GUI.
- Targeted partial-manifest handoff queue/file regression passed without further
  production changes: selected chapter 2 stayed selected. The earlier title-only
  assertion used a generated placeholder and was corrected to inspect the real
  AVPlayerItem filename. Preserve this working behavior.
- Actual GUI relaunch loaded the short chapter text but retained its spinner
  for more than 20 seconds, hiding transport. The prepared-reader readiness gate
  incorrectly requires positive scroll range, which a one-page chapter lacks.
  Add a short prepared-chapter regression before allowing completed measured
  layout to finish loading; preserve existing viewport/pagination math.

## Verification after corrections

Final reader GUI preflight found another actual app error: the 45-minute sleep
timer option exposes `player.sleepTimerOption.45` instead of localized text.
Add the missing entry in the three existing locales and exercise selection/off
in the actual SE player. Separately, the reader test must close the restored
expanded player before selecting its book; this is a harness setup correction.

- Exact SE native pending-seek/mini-player and paused Previous regressions:
  44 tests passed (`/tmp/se-streaming-controls-ui-native.log`).
- Real partial handoff and immediate TOC download badge: 2 tests passed
  (`/tmp/se-streaming-handoff-repro.log`). No additional handoff fix was needed.
- Strict real Edge transport and actual MP3 retention/replay: 2 tests passed
  (`/tmp/se-streaming-final-flow.log`). First audio was 1.8998586 seconds;
  two chapters completed in 6.879 seconds without system voice. Actual
  AVQueuePlayer rate changed to 1.5 and back to 1.
- Completed-manifest/partial-download restoration and TOC retention: 3 tests
  passed (`/tmp/se-streaming-restoration-ui.log`). Unsafe or missing conversion
  artifacts reject the conversion snapshot; retained downloads remain usable.
- Short reader layout plus complete real GUI transport/download/relaunch:
  5 native tests and 1 GUI test passed (`/tmp/se-streaming-warm-fixed-ui.log`).
  The GUI clock advanced after relaunch and both chapter controls preserved pause.
- Actual-root restoration with two books: 1 test passed
  (`/tmp/se-root-restoration-check.log`). Do not change identity selection
  speculatively: the current reader is correctly restored in this regression.

The first fallback observation was not reproduced by later strict Edge runs.
No provider timeout, voice engine or working queue handoff was changed for it.
Harness selector, stale-clock and fixture-path failures are distinct from app
bugs. Final verification completed below.

## Final acceptance and delivery

- Fresh exact-book GUI: `/tmp/se-streaming-final-fresh-ui.log`, 1/1 passed
  (66.087 seconds). GUI-observed first playback: 4.1032824 seconds.
  Fixture ID: `8354829ae28ce9a348d554f56a7a2235`; exactly two chapters.
  Its only synthesis job was `B0BD70AC-4760-4BFB-BEE9-1309CB0AF58B`;
  completed before GUI relaunch. Both completion receipts identify `edge`.
  Retained MP3 sizes are 313920 and 320544 bytes; SHA-256 matches the
  corresponding converted Edge files. Replay did not create another job.
- macOS actual executable: `mise run apple:chapter-callback:test` with focused
  `APPLE_NATIVE_TESTS` and live Edge FFI: 16/16 passed, zero skipped.
  Includes real Edge chunk playback before conversion returns, local resolution,
  retained restoration, paused navigation, and an actual LOTR reader window.
  Evidence: `/tmp/se-goal-mac-parity.log`, `/tmp/se-goal-mac-summary.json`.
- Actual LOTR SE GUI: `mise run ios:simulator:test` with
  `IOS_TESTS=EpubToMp3UITests/RealBookReaderUITests/testActualLOTRReaderPaginationAndChrome`:
  1/1 passed (25.066 seconds), `/tmp/se-goal-lotr-golden-fixed.log`.
  `clippedLineCount=0`; page 1 → 2 → 1; chrome round trips preserve advanced
  raw offset 365 and visible anchor. Existing geometry remains unchanged.
- Timer activation/cancellation native tests: 3/3 passed,
  `/tmp/se-goal-final-controls-locales.log`. Actual Portuguese timer GUI passed
  there too. An immediate English hittability assertion raced the preceding
  speed-menu dismissal; wait for actual hittability rather than change the app.
- Final rebuilt actual GUI: `/tmp/se-goal-final-controls-locales-fixed.log`,
  2/2 passed (76.023 + 12.212 seconds). Rechecks transport, seek, rate,
  downloads, relaunch, 45-minute timer selection/off in English and pt-BR.
  This proves the timer menu/actions, not waiting 45 minutes for expiry.
- Native iOS simulator FFI rebuilt after temporary diagnostics were removed;
  `/tmp/se-streaming-final-ffi.log` passed. Scoped `git diff --check` and
  `plutil -lint` on all three localization files passed.
- Specialist contract/UI audits found no additional material regression.
  Python/Ruff and repository-wide CI were not run; no physical-device claim.

Final corrected app errors: absolute Rust download paths; pending streaming
chapter catalog/priority; stale autoplay on Previous/full-file replacement;
missing pending-seek loading indication; stale TOC download badge; incomplete
partial-download restoration; short chapter stuck loading; missing 45-minute
timer translation. Initial isolated system fallback did not recur in strict
Edge verification, so no speculative provider timing change was made.

Only dedicated verification books were removed from the visible library;
their output/download/fulltext artifacts were archived reversibly under
`/tmp/se-goal-fixture-archive`. Original reading preferences and development
LOTR seed restored. Normal SE app launched without test arguments, PID 76608,
on the original LOTR reader. Final screenshot:
`/tmp/se-goal-final-normal-app.png`. Only the exact SE/iOS15.5 Simulator is
booted; no macOS app is running. Local source changes remain in the existing
dirty worktree; no unrelated changes were staged, committed or pushed.
