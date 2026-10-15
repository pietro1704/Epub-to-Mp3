# Session retrospective controls

Baseline: `1027075892`, existing `feature/architecture-hardening` branch.
This is repository workflow maintenance, preserving the branch's verified
dependencies and all unrelated pending product changes.

## Scope and acceptance

Implement all five retro recommendations: fail-fast command sequences, scoped
index transactions, native lease integration, idempotent instruction updates,
and automatic host checks with bounded discovery/output. Tests exercise public
CLIs, real temporary Git repositories and real host processes. Native commands
are fixtures; no app, Swift/Rust compilation, Simulator, GPU stability claim,
service change, publication, PR/merge or history rewrite is in scope.

## Reviewed plan and board

| ID | Owner | Depends on | Files/seam | Acceptance and status |
| --- | --- | --- | --- | --- |
| RETRO-1 | Root | Inspection | scripts/run_steps.rb and tests | Verified: 8 tests/33 assertions; failure, cancellation, timeout, descendants, implicit-shell regression and exact bounded logs |
| RETRO-2 | git_safety | Inspection | scripts/scoped_git_index.rb and tests | Verified: 15 tests/241 assertions; atomic real index, prepared sources, branch/index/worktree identity and image tampering |
| RETRO-3 | native_safety | Inspection | native launcher/preflight and host tests; root owns mise wiring | Verified host seam: launcher 11/63, actual task shells with fake Apple tools 7/20, preflight 8/48; nested descriptor and lease exclusion |
| RETRO-4 | checks_docs | Inspection | instruction patch CLI and host tests | Verified: 8 tests/44 assertions; actual workflow patch repeated without mtime change; alias, permissions, stale/ambiguous baseline cases |
| RETRO-5 | Root + checks_docs | RETRO-1..4 | host aggregate, mise/hooks, main CI and workflow docs | Verified: aggregate 2/7, hygiene 6/140 incl real repository index check; actual local preflight passed; CI configured; compact discovery/log guidance |

Plan review: each retro item maps to an observable CLI boundary. New helpers
remain small repository-owned host tools using the existing Ruby runtime.
Shared mise/TODO/instruction files belong to root; specialist file ownership is
disjoint. Existing uncommitted product/security changes stay outside delivery.

## Risks and verification

Nested Xcode phases can reenter the native lock: validate an inherited descriptor
against the actual lease file; do not use a plain bypass flag. Arbitrary external
processes remain outside cooperative coordination. Git manifests must reject
stale index/HEAD/worktree identity and preserve index locks owned by others.
Instruction aliases must update their authorized real target while retaining
the symlink. Output logs must never turn a child failure into a successful check.

Run red/green host regressions beside each tool, then an aggregate through mise,
isolated real-CLI smoke and adversarial review. Inspect the exact staged manifest
and final diff before commit/push. Do not claim GPU or native app verification.

## Actual evidence and review

`mise run host:workflow:test` first passed 64 tests/593 assertions. After adding
the real repository tracked-but-ignored gate, `mise run preflight` passed all
8 suites: **65 tests, 596 assertions, zero failures/errors/skips**. Exact step
status/duration/log paths:
`.reports/host-workflow/20261015T170556-15335/results/report.json`.

Combined real CLI smoke executed six dependent steps in a disposable Git repo:
instruction update twice, scoped index capture/stage/verify, then authenticated
nested native lease without any Apple command. Evidence retained at
`/var/folders/r_/cm8xzdc94452nmnp7t3wsnwm0000gn/T/epub-retro-smoke-20261015-14932-zfhza3/evidence/report.json`.
Nine modified task definitions parsed via mise and passed `bash -n`; main CI
YAML parsed and contains Ruby/minitest/mise setup plus the host aggregate.

Independent review found four concrete gaps, reproduced red and corrected:
single-element argv shell interpretation, failed-step orphan descendants,+self-consistent index images differing from prepared sources, and a branch
switch at the same commit. Final Spec/Standards review reports no remaining
host blocker. The tools were also exercised on their real CLI paths rather
than relying only on function tests or source presence.

No native app/build/Simulator or GPU test ran. The actual Xcode descriptor chain
and legacy Swift smoke interpreter startup remain unverified by these fixtures.
CI configuration was validated locally; no remote CI run/monitoring occurred.
Process-group and lease coordination covers cooperating tested paths, not
arbitrary commands escaping their group. UI/accessibility and synthesis
performance checks are outside this tooling-only change.
