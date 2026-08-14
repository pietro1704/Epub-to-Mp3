# Native Reader

Read this file, [`../../CONTEXT.md`](../../CONTEXT.md), and relevant files in
[`../../docs/adr/`](../../docs/adr/) before changing the native reader.

## Invariants

- Text never clips. A rendered glyph must fit wholly within the visible reader
  viewport in every supported font, size, orientation, safe-area state, and
  reader mode.
- A chrome toggle changes viewport size only. Capture and restore the active
  text surface's exact raw `contentOffset`; never substitute a saved progress
  offset or paginated page boundary during that transition.
- Canonical page offsets belong to explicit paginated page turns only.
- Hidden chrome makes the text surface respect the physical safe area exactly.
- A final, committed viewport is the only geometry that may drive TextKit
  invalidation, pagination, scroll clamping, or clipping probes.

## Reader changes

Use `$native-reader-regression` for reader, pagination, chrome, safe-area,
page-turn, EPUB/PDF-open, or expanded-player layout changes. Its evidence
gate uses the seeded Lord of the Rings EPUB and leaves the app open after an
explicit simulator verification.

For architecture work, keep a single deep module at each real seam. The
viewport transition owns transition ordering and restoration; paginated layout
owns glyph protection and page boundaries. Do not add a protocol until two
real adapters require one.

## Tests

Reader regressions belong in native XCTest or UI tests. Test the behavior at
the reader seam; do not parse Swift source as a substitute for runtime
evidence. Changes under the reader production surface require a corresponding
native test change in the same commit. The repository pre-commit hook checks
this pairing.
