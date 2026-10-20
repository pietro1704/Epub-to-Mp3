# Native reader theme correction

User request: correct dark/light colors and reader themes using specialists.
Baseline: `b7309f78aa`; unrelated product work remains outside this delivery.

## Plan and acceptance

| ID | Owner | Scope / dependencies | Acceptance / evidence | Status |
| --- | --- | --- | --- | --- |
| COLOR-1 | Contract specialist | AppSettings palette, HTML renderer, prepared render signature | One settings-aware native palette; real named/custom colors; contrast on actual colors; preserve original light CSS when overrides off and links/typography | Implemented; native regressions verified |
| COLOR-2 | Root | UIKit BookOpen/MainReader; COLOR-1 API | Apply saved theme at opening and updates, consistent page/loading/root/control colors, honor custom RGB, preserve raw viewport/progress | Verified iOS |
| COLOR-3 | AppKit specialist | MacReaderTheme/controller; COLOR-1 API | Current settings applied after publication; matching page/text/toolbar/link colors; preserve viewport on color-only changes | Verified macOS |
| COLOR-4 | Runtime specialist / Root execution | Native tests and UI journeys; COLOR-1..3 | macOS + exact SE1/iOS15.5 light/dark/sepia/custom; opposite OS appearances; actual screenshots and geometry checks; build/Simulator separation | Verified |
| COLOR-5 | Root + independent reviewers | Final diff/task reconciliation | Focused checks, source-fidelity evidence, scoped commit/push; no unrelated edits | Final audit passed; scoped delivery |

Use goal-plan-execute and native-reader-regression. No runtime/provider change,
model download, library/progress reset, external publication/merge or CI monitoring.
The existing feature branch holds the verified reader dependency; this is a focused
regression continuation, not a new architecture or renderer replacement.

Palette seam: settings.readerColors (native background/foreground/link including
custom RGB) and settings.readerPreferredColorScheme (auto inherits OS; explicit
named/custom themes align controls with page brightness). Light/dark palette values resolve native Apple semantic colors; warm palettes
retain their explicit values. The renderer stops owning a different table. Light + colors-override disabled preserves author inline colors;
other selected themes override text/link colors and remove inline page backgrounds.
Retain link destinations, font weights/italics, hierarchy, images, resources and
fallback text. Invalidate prepared render archives when color semantics change.

Separate color application from layout. Appearance updates must not change the
raw offset, active chapter, glyph protection, canonical page boundaries or chrome
transition ownership. Tests cover current text/page/root matching, custom RGB
changes, and runtime color contrast rather than a handwritten unrelated table.

## Evidence

Initial supplied SE screenshot shows a black outer page with a differently colored
text rectangle and links. Specialists confirmed duplicated renderer/surface palettes,
custom color overwrite, missing initial UIKit surface paint and AppKit reading
objectWillChange before its published setting changes. Source inspection is
hypothesis evidence; failing native regressions and actual apps are required.

Exact target retained from the previous verified task: SE1/iOS15.5
C66CCB36-C43E-4174-861E-2FA713389C84, Xcode16.4. The root shut it down under the
native lease before compilation; prerequisite checks will run before each build.
Results and limitations will be appended after execution.

## User correction: Apple colors and equal material policy

The user explicitly required Apple colors and the same transparencies in light
and dark. Use UIKit `systemBackground`, `label`, `link` and AppKit
`textBackgroundColor`, `textColor`, `linkColor`; do not substitute invented blue
or gray constants for the default light/dark appearance. Auto follows its host.
Retain the current native transparent navigation appearance and the same
`AdaptiveMaterialView` instance/material/alpha across both modes, including the
mini player. Do not paint an opaque replacement over native materials. AppKit's
existing toolbar structure/opacity remains identical in both appearances.
Warm and custom themes remain reader options, not claimed as Apple Books colors.

Native semantic colors and material resolution follow Apple's APIs:
[system material](https://developer.apple.com/documentation/uikit/uiblureffect/style/systemmaterial),
[link color](https://developer.apple.com/documentation/uikit/uicolor/link),
[AppKit text background](https://developer.apple.com/documentation/appkit/nscolor/textbackgroundcolor),
[color-appearance changes](https://developer.apple.com/documentation/uikit/uitraitcollection/hasdifferentcolorappearance(comparedto:)).
A measured contrast ratio applies only to the tested adjacent colors; these
checks are not full accessibility certification. The [W3C contrast guidance](https://www.w3.org/WAI/WCAG21/Understanding/contrast-minimum.html)
requires actual adjacent colors, so the old handwritten reference palette was
replaced with assertions against production colors. Native link identity is
verified rather than claiming an unmeasured 4.5:1 ratio for Apple's colors.

## Red evidence

- First new AppKit test required an optional-dictionary compile correction; that
  failed build was not counted as runtime reproduction.
- Actual macOS red: 26 tests, 23 passed / 3 failed, no skips. Failures reproduce
  different renderer/page colors, indistinguishable link/body colors and live
  changes painting the prior theme. Exact output and parsed summary:
  `.reports/reader-theme-20261015/mac-red/report.json` and `mac-red-summary.json`.
- Actual SE1/iOS15.5 red: all five new reader color tests failed, no skips,
  covering initial appearance, authored light color, warm palettes, custom RGB
  and live theme updates. Build and test were separate phases. Exact output and
  parsed summary: `.reports/reader-theme-20261015/ios-red/report.json` and
  `ios-red-summary.json`. Simulator was shut down before green compilation.

## Implementation and review

UIKit applies saved colors at initial mount and on committed settings changes;
root, loading surface, viewport, text and masks use the shared palette. It leaves
the existing transparent navigation bar and adaptive material unchanged. Color
changes rerender through the current prepared renderer and restore exact raw
offset when typography/layout/margins are unchanged; custom RGB participates in
style identity. A pending change during initial loading is reconciled afterward.
AppKit defers published settings reads, restores the exact clip origin and
preserves authored light colors rather than recoloring all NSTextView content.
The prepared renderer signature is version 3 to reject old palette archives.

Adversarial review caught a blanket AppKit textColor assignment that erased
explicit body/link colors. A native red test reproduced it with red body, green
link and yellow highlight; the correction preserves these in original light
mode and keeps body/link colors separate in override modes. Exact red log:
`.reports/reader-theme-20261015/authored-red/report.json`. Xcode emitted a result
bundle saving warning in this failed run; command/native logs remain the evidence.
The importer also omits some default foregrounds; only missing colors now get
native text/link defaults, preserving declared publisher styling.

One existing AppKit page-anchor fixture measured text before initial saved-position
restoration completed. It now awaits the existing scheduler's real completion,
retaining the same scroll, anchor and persisted-progress assertions. Raw failed
outputs are retained under `mac-first-green` and `mac-second-green` in the local
report directory; normalized RGBA comparisons replace invalid equality between
identical colors stored in different color spaces.

Source-fidelity gates use the actual HTML renderer regressions: headings and
centering, bold/italic, semantic blocks/lists/captions, data/relative/percent-encoded
images/resources, fragment/relative links, original CSS colors and plain-text
fallback. These are runtime fixtures; the seeded LOTR runs supplement them with
native display/geometry evidence. No parser/sanitizer rules, imported source,
font metrics or image pipeline are redesigned.

## Verified macOS results

The full focused selection passed **57 tests**, no failures or skips, including
HTML source fidelity, real palette contrast, native link identity, prepared-cache
behavior and AppKit theme/page controls. Xcode returned zero but reported an
xcresult saving error (`mkstemp`); the actual XCTest stdout, suite counts and
command status are retained in `.reports/reader-theme-20261015/mac-green/`.
Do not describe this as an intact full-suite xcresult bundle.

A stronger theme test then reproduced the playback-anchor reset to zero despite
the restored visible page. Exact red evidence is in
`.reports/reader-theme-20261015/anchor-red/native-output-0.txt`.
Republishing progress after the restored viewport fixes it. The final affected
AppKit selection passed **8/8**, no skips, after this change, independently read
from xcresulttool: `.reports/reader-theme-20261015/mac-final-summary.json` and
`mac-final/report.json`. Saved fractional progress uses the same half-point
visible-position tolerance (the observed rounding difference was below 0.16pt),
while the audio anchor and raw offset retain their own assertions.
UIKit likewise explicitly republishes progress after a theme restore; its test
now turns a real page and verifies nonzero reading/audio anchors survive.

The macOS test host exited before iOS compilation. The SE remains shut down
through the build phase; execution uses the existing artifacts afterward.
Source/rendered styles were independently reviewed again after the fixes; no
remaining concrete code blocker was found. Final iOS and host results follow.

The user's Apple-color/material preference is now part of the repository's
[review standards](../../../CODING_STANDARDS.md), reached through existing
agent instructions. It is not duplicated into a harness-only memory store.

## iOS transition diagnostics

The first green selection ran 66 tests: 62 passed, three failed, one skipped.
All saved/warm/custom palette and native material assertions passed. The existing
PNG downsampling fixture intentionally skips on UIKit and passed on AppKit.
The new page-turn fixture initially acted before deferred gestures became ready;
it now disables that opening-tap deferral for its directly mounted controller.
The two seeded UI cases sampled a sheet-transformed window-coordinate probe
after waiting on a nonexistent cell identifier. They now wait on the actual Done
button and require stable probe coordinates matching the visible scroll frame;
raw offset, visible anchor, page count and viewport comparisons remain strict.
Exact initial summary/screenshots: `.reports/reader-theme-20261015/ios-first-green/`.
The stricter rerun passed all seven UIKit tests and reproduced stale UI probe
coordinates in both UI cases: probe 98/458 versus actual viewport 76/476, with
unchanged 400pt viewport height. Exact red summary: `ios-transition-red/summary.json`
under the same local report root. The settings Done dismissal now refreshes only
the diagnostic probe from UIKit’s dismissal completion, after the final native
presentation transform. It does not invalidate layout, paginate or move the page.
The affected native/UI selection is rerun after this correction.

An independent final production review found no remaining concrete blocker in
semantic colors, material/alpha policy, authored styling or progress ownership.

Local required host gate: `mise run preflight` passed 65 tests / 596 assertions,
no failures/errors/skips, across all eight suites. Exact evidence:
`.reports/host-workflow/20261015T183303-41010/results/report.json`.
The six research documents have 31 valid local links/anchors.

## Final iOS results

Final affected selection passed **13/13**, no failures/skips: seven actual UIKit
color/material/anchor tests, four viewport transaction tests and two seeded LOTR
UI journeys (dark under light OS, light under dark OS, then live theme changes).
The strict raw-offset, visible-anchor, page-count and final-viewport comparisons
pass after Done, and clippedLineCount remains zero. Initial viewport coordinates
were 76..476pt on the SE. Both final screenshots were visually inspected.

Exact final commands and summary: `.reports/reader-theme-20261015/ios-final/`.
Result bundle: `.reports/simulator-smoke-8592A75D-1169-4A73-A396-BE513A7FCE5B/tests.xcresult`.
Six retained UI screenshots and their manifest are in `ios-final/attachments/`.
The earlier broader 66-case run additionally verified renderer/source fidelity,
prepared chapter/cache integration and interrupted chrome behavior: 62 passed,
three newly added cases subsequently corrected/passed, one intentional UIKit
image fixture skip covered by macOS. Do not report the initial run as all green
or sum repeated selections as unique coverage.

Verification used Xcode16.4 and separate build-for-testing/test-without-building
phases; all Simulators and SimMetalHost were absent before each compilation.
No provider, model, playback audio or conversion configuration changed. No GPU
driver stability guarantee or full accessibility certification is established.

Final visible state: the existing freshly verified app was resumed without build,
and left open on seeded LOTR in dark mode on the required SE. Root inspected
`.reports/reader-theme-20261015/final-se.png`; native macOS test hosts had exited.
