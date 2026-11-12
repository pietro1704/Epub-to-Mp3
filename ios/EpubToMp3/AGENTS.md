# Native Reader

Read this file, [`../../CONTEXT.md`](../../CONTEXT.md), and relevant files in
[`../../docs/adr/`](../../docs/adr/) before changing the native reader.

## Invariants

- Text never clips. A rendered glyph must fit wholly within the visible reader
  viewport in every supported font, size, orientation, safe-area state, and
  reader mode.
- Chrome overlays the fixed chrome-free reader viewport. Toggling bars preserves
  text geometry, page boundaries and the exact raw `contentOffset`; capture and
  restore that offset without substituting saved progress or a page boundary.
- Canonical page offsets belong to explicit paginated page turns only.
- Hidden chrome makes the text surface respect the physical safe area exactly.
- A final, committed viewport is the only geometry that may drive TextKit
  invalidation, pagination, scroll clamping, or clipping probes.

## Reader changes

Follow [execution policy](../../docs/agents/execution-policy.md) for current
native safety and acceptance. Authorized Simulator work uses only the reviewed
supervisor described there; this reader contract does not authorize a boot.

Reader acceptance requires the native macOS app and iPhone SE (1st generation)
Simulator on iOS 15.2 with Xcode 26.3 (`/Applications/Xcode-26.3.0.app`). A physical
iPhone or another runtime cannot substitute for that required target. Verify
available targets without booting a device; record unavailable or prohibited
runtime acceptance as pending. XCTest supplements the actual visible app journey.

Use `$native-reader-regression` for reader, pagination, chrome, safe-area,
page-turn, EPUB/PDF-open or expanded-player layout changes. Its seeded Lord of
the Rings EPUB and retained screenshots/reports provide the evidence contract.
Use [macOS validation](../../docs/agents/macos-validation.md) for the Mac path.

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
