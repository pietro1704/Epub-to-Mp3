# Native Apple UI corrections

Status: verified; PR delivery pending

## Problem and outcome

Audit every shipped native screen and correct concrete layout, navigation and
accessibility defects on iPhone SE, Pro Max and resizable macOS windows. Preserve
existing reading, playback, downloads and Rust conversion behavior. Use UIKit
and AppKit system controls appropriate to the supported OS, following Apple's HIG.

## Acceptance and verification

- All screens inventoried, including secondary forms, logs and empty/error states.
- Long localized labels remain readable; controls stay reachable in small and
  landscape viewports and with accessibility text sizes.
- Native semantic colors, labeled controls, keyboard access and system navigation.
- Reader raw offsets and glyph protection remain intact; seeded LOTR regression.
- Execute actual native tests and exercise the installed apps on SE/iOS15.5,
  iPhone 13 Pro Max/iOS15.5 and macOS with Xcode16.4, one target at a time.
- Record exact passed checks and unverified acceptance. Deliver authorized
  changes through a feature branch and PR; no CI monitoring.

## Sequential tasks

Screen inventory (static review, runtime evidence still pending):

| Surface | iOS | macOS | Audit decision |
| --- | --- | --- | --- |
| Library/search/filter/import/empty | LibraryScreen/Grid | MacLibrary | Empty-state scroll, semantic fonts, accessible toolbar |
| Book detail/actions/progress | BookDetail | MacBookDetail | Scroll, readable labels and vertical actions |
| Reader/empty/search/TOC/footnotes | MainReader/BookOpen/Toc | MacReader | Preserve viewport; Dynamic Type empty state, accessible settings |
| Reader appearance/options | ReaderSettings | MacReader popover | Keep native forms; label Mac controls |
| Persistent and expanded players | MiniPlayer/FullPlayer | Mac root player views | Preserve compact layout; fonts, names, scroll Mac expanded |
| Manual conversion/options/errors | Convert | Book detail conversion action and native errors | Shared iOS inline field accessibility/layout |
| Jobs/detail/chapter outputs | JobsList/JobDetail | MacJobsList | Native tables; refresh label and scaled iOS diagnostic font |
| Job player | Player | Expanded player | Responsive scroll, flexible artwork and accessible transport |
| Settings/storage/downloads | Settings/LocalAudioDownloads | MacSettings | Native tables; shared field fixes, adaptive Mac scroll |
| Logs/telemetry/conversion log | Logs/Telemetry/RustLog | RustLog | Scale iOS diagnostic fonts; preserve native scroll text |
| App navigation/menus | IOS shell | Mac root/app menu | Preserve system containers; add standard Mac Settings shortcut |

The audit targets concrete defects rather than restyling working native screens.
Compatibility remains iOS15/macOS12; no newer visual API is required.

1. Inventory and HIG review. No blockers. Read-only specialist passes over iOS
   and macOS controllers and existing tests. State: verified (static inventory).
2. Responsive native forms and book actions. Depends on 1. Shared form cells,
   book-detail controllers and settings. Runtime XCTest at actual view seams;
   no source-contract tests. State: verified (native iOS and Mac tests).
3. Player and secondary screen corrections. Depends on 2. Correct only defects
   established in the audit. Test actual control geometry/accessibility. State:
   verified (native iOS and Mac tests).
4. App verification and adversarial QA. Depends on 3. Native test and GUI paths
   on Mac, Pro Max and SE; keep SE open last. State: verified.
5. Final Standards/Spec review and delivery. Depends on 4. Scoped diff review,
   mise run preflight, commit/push, PR and automatic merge if available. State:
   verified locally; delivery pending.

## Risks and rollback

Auto Layout constraints and scroll documents can affect reader host sizing.
Keep changes at affected UI seams; preserve reader viewport implementation.
Rollback consists of reverting the UI slice and its paired tests.

## Execution log

- 2026-10-14: User confirmed all screens and navigation corrections where
  necessary, and authorized sequential execution. Created feature/apple-ui-hig
  from fetched master ea3e5705b5; unrelated .ai-jail/.ai-memory.toml preserved.
  Xcode16.4 lists exact SE/iOS15.5 and native Mac destinations. Created Pro Max
  verification Simulator using installed iOS15.5; no runtime download.
  Initial inspection proves fixed-width button rows and non-scroll content in
  book details, fixed-width Mac settings, and job-player constraint conflicts.
  HIG sources: https://developer.apple.com/design/human-interface-guidelines/layout
  and https://developer.apple.com/design/human-interface-guidelines/accessibility
  and https://developer.apple.com/design/human-interface-guidelines/buttons.
- 2026-10-14: Native forms red: 2 tests / 5 assertions failed; green: 2/2 passed
  on exact SE. Responsive screen red: 3 iOS tests failed; Mac book/Settings red:
  2 tests / 3 assertions failed. Added native scroll hosts and corrected actions,
  metadata fonts, accessible controls and standard Mac Settings shortcut.
- 2026-10-14: Mac focused run passed 10/10 including real LOTR final-glyph,
  text layout, menu, resizing, settings navigation, reader popover and accessible
  library import. Xcode reports success but warns while saving the xcresult
  activity log; raw evidence retained in /tmp/apple-ui-mac-final.log.
  A broader existing MacReaderChapterNavigationTests run had 2 stale assertions:
  playback page-start ratio expected 1 instead of observed 0.91. Actual reading
  end progress=1 and final glyph visibility passed. UI changes do not alter that
  reader logic; preserve the page-start audio anchor and record this suite limit.
- 2026-10-14: Actual Mac app opened, Settings invoked through Command-comma and
  window resized. Visual review caught inconsistent row alignment despite
  geometry tests passing; refining the native grid before final verification.
- 2026-10-14: Final Mac native grid passed 10/10 focused checks again. Actual
  app Settings, Library, Jobs and reader opened through native GUI automation;
  window exercised at 1000x700 and 1250x850. Screenshots in /tmp/apple-ui-mac-*.png.
  Original LOTR selection restored after visual reader inspection; Mac exited
  before switching platforms. Final log: /tmp/apple-ui-mac-grid-final.log.
- 2026-10-14: Adversarial iOS review reproduced an expanded-player overflow:
  metadata/control group was outside the cover-only scroll. Native test red
  failed; moved the whole content to one scrolling surface with a preferred
  viewport-height fit to keep normal controls bottom-aligned. Compact/landscape
  AX checks now pass. Also reproduced library AX metadata clipping: available
  title/author heights 62/0 versus required 115.7/50.3 points. Layout now reserves
  scaled font line heights; native test confirms actual accessibility font sizes.
- 2026-10-14: Pro Max final run passed 9/9 native + 2/2 real GUI tests. English
  normal text and PT-BR accessibility XXXL cover tabs, Settings scroll, native
  file-picker cancellation and landscape fields. Dark appearance verified in
  Simulator screenshots. Final log: /tmp/apple-ui-promax-verified.log; result:
  .build/Logs/Test/Test-EpubToMp3-2026.10.14_13-42-21--0300.xcresult (see log for exact path).
  Earlier broad MiniPlayer suite contains one stale test expecting 112/156-point
  height instead of the existing 60/104-point compact policy; production policy
  is unchanged. Other 16 MiniPlayer tests passed. Focused actual expanded-player
  controls test passes in final run. Do not restore obsolete heights.
- 2026-10-14: Pro Max shut down. Backed up three SE app/widget preference files
  before GUI tests. SE final suite includes native geometry, English/PT-BR GUI,
  actual LOTR default/small text pagination and player presentation, interrupted
  chrome toggles, landscape glyph protection and scroll chapter controls.

- 2026-10-14: Closing review reproduced reused table-cell accessibility labels
  leaking across Settings/Convert rows and a long expanded-player author being
  compressed during live accessibility scaling. Native regression tests failed
  before corrections and passed afterwards on SE and Pro Max. Pro Max closing
  run: 10 native + 1 English GUI test passed (/tmp/apple-ui-promax-closure.log).
  SE closing run: 10 native + English GUI + real LOTR default/player passed
  (/tmp/apple-ui-se-closure.log). Final PT-BR accessibility XXXL navigation,
  file-picker cancellation and landscape passed (1 GUI test, 122.676 seconds;
  /tmp/apple-ui-se-portuguese-closure.log). Five real reader regressions passed
  in /tmp/apple-ui-se-final.log, including small text, interrupted chrome,
  landscape glyph protection and chapter controls.
- 2026-10-14: Standards review additionally found disabled action traits surviving
  table-cell reuse. A native lifecycle regression reproduced raw traits 257
  instead of the default 0; prepareForReuse now resets traits alongside labels.
  Final focused verification is recorded below after execution.
- Coverage limit: every screen was inventoried and reviewed, while installed-app
  execution sampled affected paths and reader regressions. Unchanged error and
  dialog states were not exhaustively exercised. No audio was deliberately
  played. Broad pre-existing stale assertions above remain out of this UI scope.
  Local Python/Ruff and broad Rust gates are deferred to CI. Xcode sometimes
  warns while saving xcresult activity logs despite successful tests; raw logs
  retain the actual executed results. This is not a claim of exhaustive HIG
  certification.

- 2026-10-14: Final SE cell-traits regression passed, together with all forms and
  responsive geometry tests: 10/10, zero failures (/tmp/apple-ui-traits-green.log;
  .build/Logs/Test/Test-EpubToMp3-2026.10.14_14-28-44--0300.xcresult). This final
  iOS-only lifecycle reset was not rerun on Pro Max; its prior closing run covers
  the otherwise identical UI. No Mac source changed after its verified run.
  mise run preflight and mise run hooks:reader-check both passed. Owned staged
  diff passes git diff --cached --check. Review found no remaining scoped blocker.
