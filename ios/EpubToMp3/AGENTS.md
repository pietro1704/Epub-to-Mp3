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

For every feature or bug fix, verify the real iOS app on the iPhone SE
(1st generation) Simulator running iOS 15.5 and verify the native macOS app.
For this project, run iOS Simulator builds, tests, and launches with Xcode 16.4
(`/Applications/Xcode-16.4.0.app`); newer Xcode installations may not list this
legacy destination. The physical iPhone is not a substitute for this required
Simulator target.
Run only one native app/Simulator target at a time. Before switching targets, quit the
active app and shut down its Simulator; verify it exited before opening the next.
After verification or whenever idle, close the app, shut down its Simulator, quit Simulator.app and confirm shutdown. Retain screenshots/reports as evidence.
Check that this exact Simulator destination and the macOS target are available
before implementation; do not substitute another runtime or device. Install,
launch, and exercise the affected behavior in each app. XCTest/UI tests supplement
this evidence. If either app cannot be run, record the blocker and keep the change
unverified.

Use `$native-reader-regression` for reader, pagination, chrome, safe-area,
page-turn, EPUB/PDF-open, or expanded-player layout changes. Its evidence
gate uses the seeded Lord of the Rings EPUB and retained screenshots/reports; close the Simulator after active verification.

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

## Agent-host panic response

After any new user-reported or observed kernel panic, stop initiating local processes on the affected host. Do not run shells, builds, tests, Simulator/device actions or resource-intensive tasks there; do not reboot, retry, stress the host, or alter hardware/firmware automatically. Continue only through GitHub-hosted Actions or remote tools that start no process on the affected host. Resume local execution only after the user confirms host stability. Read the canonical [host panic response](../../docs/agent-workflow.md#response-to-an-agent-host-kernel-panic). This limits exposure and does not prove or fix a hardware cause.
