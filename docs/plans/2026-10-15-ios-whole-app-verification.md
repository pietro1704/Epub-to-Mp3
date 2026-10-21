# Whole-app iOS 15 verification campaign

> **Historical record (reviewed 2026-10-21).** Unclosed historical whole-app campaign. Intel Simulator quarantine blocks its boot-after-build recipe and required SE1/iOS 15.5 acceptance remains pending. An old unattended campaign prompt does not start a new campaign. Use [execution policy](../agents/execution-policy.md) for current scope, guarded builds and Simulator quarantine, and [runtime navigation](../agents/runtime-navigation.md) for architecture; old commands and authorizations are retained only as evidence.

## Scope and authorization

Verify the current native app on iPhone SE (1st generation), iOS 15.5,
using Xcode 16.4. Preserve imported books, progress, installed models and all
pre-existing dirty work. The user authorizes unattended execution, specialist
review, separate branches and PRs per feature/bug, push and merge to master
after green required checks. Continue independent work around blockers and
report user-dependent items rather than asking questions during this campaign.
No implicit model download, paid provider, online fallback or physical Apple
device. Samsung actions belong to the explicitly authorized Flutter follow-up.

Canonical instructions and this request govern execution; historical reports
identify risks but do not certify the current source or authorize new actions.

## Safety gates

1. Read-only inventory: exact destination, current native processes, artifacts,
   source identity, hook wiring, disk and repository divergence.
2. Review this plan with native-safety, UI/state and conversion/Git specialists.
3. Before every compilation, stop the current app, shut down its Simulator,
   confirm all Simulators are Shutdown and SimMetalHost has exited. Run
   `mise run native:build:preflight`; acquire the existing native heavy-job lease.
4. Build-for-testing with one job, parallel testing disabled and Simulator off.
   Boot only the required destination after compilation exits; reuse compatible
   artifacts through test-without-building. Native processes run serially.
5. Do not change Metal/renderer/driver settings or reproduce the kernel panic.
   Extract xcresult evidence through the per-bundle wrapper. Stop on new unsafe
   state; pursue read-only analysis or unrelated checks while blocked.
6. User correction: close the app, shut down its device and quit Simulator.app
   whenever active verification stops, including between phases and at the end.
   Confirm shutdown; preserve screenshots and reports instead of leaving it idle.

## Work board and acceptance matrix

| ID | Surface | Acceptance and evidence | Owner | Status |
| --- | --- | --- | --- | --- |
| IOS-ALL-1 | Preferences/plan | Harness and ai-memory read-back; three specialist reviews | Root | In progress |
| IOS-ALL-2 | Safety/baseline | Exact SE1/iOS15.5; hooks/lease checks; source/artifact identity | Root + runtime specialist | Pending |
| IOS-ALL-3 | Library/import | List/search/open, identity/persistence, invalid input and empty states | Root + UI specialist | Pending |
| IOS-ALL-4 | Reader | Seeded LOTR; typography, navigation/chrome, scrolling/pagination, raw offset and zero clipped glyphs | Root | Pending |
| IOS-ALL-5 | Themes/preferences | Apple semantic colors; same native materials in light/dark; explicit reader themes and persisted settings | Root | Pending |
| IOS-ALL-6 | Playback | Play/pause/seek/chapter changes; expanded player; queue ownership; relaunch recovery | Root | Pending |
| IOS-ALL-7 | Conversion | Explicit local provider policy; first playable artifact; progress/cancel/failure; no implicit downloads/Edge | Root + conversion specialist | Pending |
| IOS-ALL-8 | Accessibility/layout | Small SE viewport, identifiers/labels, large text if supported; rendered audit limitations explicit | Root | Pending |
| IOS-ALL-9 | Delivery | One evidenced bug/feature per branch/PR, reviewed diff, green checks, merge visible in master | Root + review specialist | Pending |
| IOS-ALL-10 | Native macOS | Stop SE first; exercise actual Mac app separately; stop Mac app whenever idle | Root | Pending |
| IOS-ALL-11 | Flutter follow-up | Separate branches; corresponding changes, Samsung physical/Android and Linux app on Arch; display/Wayland readiness checked | Arch owner | Pending |

Library coverage explicitly includes Book Detail Read/Listen/Convert, EPUB and
PDF import, invalid files, cancellation and relaunch identity. Conversion/history
includes local Jobs/detail/logs/artifact sharing and empty/error states. Settings
includes storage confirmation cancellation, local downloads, diagnostics and
unsupported remote states. Effective font metrics must distinguish small/default
typography; differently named tests alone are insufficient.

Manual conversion currently has no screen-level cancellation path. Distinguish
that product gap from verified Rust cancellation; do not infer one from the other.

## Branch and evidence strategy

Inventory master divergence before choosing a baseline. Use isolated worktrees
to preserve dirty work; do not silently fold unrelated existing implementation
into a campaign PR. Dependencies that are absent from master are blockers to
independent delivery until their exact scope is reviewed and verified.

First run existing focused native tests and real app journeys. Record source
commit plus dirty-diff fingerprint, exact commands, destination, test counts,
screenshots and xcresult paths. Reproduce each defect before modifying it.
Implement the smallest slice, exercise the real app, add permanent regression
coverage, then rebuild with Simulator off and rerun the affected tests.
Reader fixes also require native macOS verification under the existing contract.

Final reporting separates verified, failed, skipped and blocked journeys. A
fixture or historical result is never reported as new synthesis, actual audible
playback, performance evidence or comprehensive app certification.

## Specialist review and execution evidence

Three independent read-only specialists reviewed this plan before native execution:
runtime/safety (retro_xcresult), UI/state (retro_doctor), conversion/Git isolation
(retro_installer). Their required refinements are incorporated above and below.

- Safety: fix two async hooks that bypass the native lease/preflight before
  proceeding. The Simulator is initially booted; all compilation must wait.
  Avoid generic ios:test (may choose a phone), vendor:python and automatic disk
  cleanup. Protect the existing derived-data cache, do not download dependencies.
- Git identity: master is initially 15 commits behind HEAD; dirty Rust/native
  changes are pre-existing. Current-workspace results cannot certify a clean PR
  SHA. Use a separate master-based branch/worktree per independently deliverable
  change. Never batch-merge the older product work without its own review.
- Runtime limits: bounded test batches, one native job, no parallel destinations.
  Reuse only exact-source-compatible artifacts, otherwise build first with all
  Simulators off. Fingerprint the selected source before and after compilation.
- CI has no full native app gate. Green remote checks supplement the exact local
  native evidence; they cannot replace real SE verification.
- iOS15.5 cannot perform the iOS17 rendered accessibility audit. Explicit native
  control, label, geometry and screenshot checks remain in scope.

The root campaign build completed with all Simulators shut down: Rust/FFI, project generation and build-for-testing all exited zero. Source fingerprint was unchanged. The first bounded SE runtime batch is in progress; no result is claimed yet. Hooks were repaired and host-tested independently (22 tests/148 assertions); safety PR #802 has its dedicated host CI green while broader checks are pending.
