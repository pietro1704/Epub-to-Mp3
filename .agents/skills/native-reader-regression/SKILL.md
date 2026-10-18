---
name: native-reader-regression
description: Verify and repair native Apple reader regressions. Use for reader pagination, clipped text, chrome toggles, safe-area geometry, page turns, EPUB/PDF opening, seeded Lord of the Rings checks, or expanded-player spacing.
---

# Native Reader Regression

Build a tight runtime feedback loop before changing reader behavior. The
non-negotiable result is no clipped glyphs and no location drift.

## Read the contract

Read `ios/EpubToMp3/AGENTS.md`, `CONTEXT.md`, and the relevant reader ADRs.
Use their terms: chrome-stable reader viewport, protected fragment, canonical
page offset, and final viewport geometry.

## Reproduce on the real surface

Use the seeded Lord of the Rings EPUB in paginated mode. Exercise the user
path that failed before editing:

1. Open an advanced page using native book typography.
2. Test small font size as well as the default size.
3. Toggle chrome once, repeatedly, rapidly, and with a second toggle before
   the first settles.
4. Turn pages in both directions with chrome visible and hidden.
5. Test the first and final page, then scrolling mode separately.
6. Test EPUB and PDF selection/opening when import behavior changes.

Do not treat a screenshot, source inspection, or a probe that excludes partial
fragments as evidence that the bug is fixed.

## Measure the invariant

Use native XCTest/UI automation and the pagination probe. Assert all of these:

- `clippedLineCount` is zero and every intersecting protected fragment fits.
- A chrome round trip restores the same raw viewport offset and visible anchor.
- The last requested chrome state wins after an interrupted transition.
- Paginated navigation lands only on canonical page boundaries and animates
  horizontally.
- Small native serif text has neither clipping nor unexplained large blank
  space.

Add the narrowest permanent native test that is red on the reported behavior.
Run the matching native test target only after explicit user authorization for
the local simulator/device. Respect the repository resource guard; do not
override it from this skill. Follow `docs/agent-workflow.md`: verify all
Simulators are shut down and SimMetalHost has exited before compiling; finish
build-for-testing before booting, then run test-without-building from valid
artifacts with one job and parallel testing disabled.

## Hand off visible evidence

Capture the seeded Lord of the Rings state, test command and relevant probe
values. When active verification ends, close the app, shut down its Simulator,
quit Simulator.app and confirm shutdown; retain screenshots/reports for inspection.
