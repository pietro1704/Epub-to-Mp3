# Phase 6: coverage, evidence and delivery reconciliation

Status: checkpoint and TODO captured; final closure/acceptance remains pending.
Return to the [audit overview](../2026-11-03-complete-code-audit.md).

- [x] Record published source commits and point-in-time delivery identities.
- [x] Separate implemented/static-reviewed work from native/Web suites not run.
- [x] Preserve #1072's checkpoint and all unrelated files/evidence; record the
  user's subsequent authorization to lift its draft hold and merge it.
- [x] Save [execution checkpoint](execution-checkpoint.md) and [remaining TODO](TODO.md).
- [ ] Reconcile all remaining source-file coverage and findings across six phases.
- [ ] Execute the final runtime matrix, resolve failures and confirm integration.
- [ ] Record blocked platform/device checks without substituting another runtime.

## Outcome and prerequisites

Give the next agent and the user a verifiable account of what was reviewed,
what changed, what passed, what remains blocked and what was intentionally kept.
Use the same ledger throughout phases 1-5; reconcile it here after their scoped
deliveries. Do not postpone regression evidence until this final phase.

Apply [coding standards](../../../CODING_STANDARDS.md),
[delivery workflow](../../agent-workflow.md),
[execution policy](../../agents/execution-policy.md) and
[platform ownership](../../agents/mac-arch-collaboration.md).
The original planning request did not itself authorize these deliveries; the
later execution instruction and current checkpoint define the active scope.

## Step 1: define finding and coverage records

Use stable IDs such as `ORG-001`, `SWIFT-001`, `BUILD-001`, `RUST-001` and
`FLUTTER-001`. Assign one editing owner and bounded paths to each executable item.

| Field | Required content |
| --- | --- |
| Identity | Finding ID, phase, owner, source SHA and affected paths |
| Classification | Confirmed bug, hypothesis, improvement, documentation drift or removal candidate |
| Priority | User impact, reproducibility, reach, data integrity and dependencies |
| Expected behavior | Independent contract, known fixture output or measurable invariant |
| Observed evidence | Exact source reference or reproduction; distinguish static and runtime evidence |
| Proposed scope | Smallest coherent change and preserved behavior |
| Approval | Exact consequential/deletion/compatibility decision, if required |
| Verification | Owning runtime, success and relevant failure/cancellation/identity cases |
| Delivery | Branch, commit, PR, exact-head required checks and merge SHA |
| Remaining limits | Unrun, skipped, unavailable, blocked or rejected checks with reason |

Suggested priority definitions: P0 for established critical integrity/security
failure; P1 for a broken primary workflow or reproducible loss; P2 for a bounded
functional/performance defect; P3 for maintenance/documentation improvements.
Confidence is a separate field. A speculative risk is not a confirmed P0 bug.

Coverage states are `not reviewed`, `reviewed`, `finding open`, `excluded with
reason` and `blocked`. A reviewed file need not have a finding. A completed fix
does not imply that every neighboring file was audited.

## Step 2: verify coverage completeness

1. Reconcile the initial tracked-path inventory against the final tree, accounting
   for additions, moves and removals. Map every owned module/test/resource family
   to a reviewed item or explicit exclusion; list generated/vendor boundaries.
2. Include application entrypoints, adapters, scripts, task definitions and
   packaging. A language-only search misses important product paths.
3. Cross-reference each substantive finding with its reproduction, decision and
   regression. Mark unresolved static suspicions as hypotheses rather than
   presenting them as fixed bugs or silently dropping them.
4. Keep Python/Web/Ruby full-audit scope explicit. Shared changes still require
   affected-consumer validation even if a full audit of those clients is deferred.
5. Compare declared review coverage with actual inspection records. Report gaps
   by module and platform, not a misleading overall completion percentage.

## Step 3: execute and close one finding at a time

1. Reproduce against the current baseline and confirm the expected result from
   an independent oracle. Narrow the failing seam before changing production.
2. Make one scoped change. Behavior fixes need a meaningful regression in the
   owning runtime; tooling changes need executable boundary checks; documentation
   needs content/link/diff validation. Demonstrate failure before a bug fix when
   feasible and record why if infeasible.
3. Cover success and relevant failure, cancellation, stale callbacks or identity
   replacement. Include persistence/relaunch when state survives the process.
4. Run the focused checks and, for behavior changes, the original user journey on
   the required target.
   Avoid broad repeated suites once acceptance is established without new risk.
5. Review the full owned diff independently against the request, evidence and
   resource cost. Verify unrelated bytes, fixtures and user data are preserved.
6. Record `passed`, `failed`, `blocked` and `not run` distinctly. Skips, source
   registration, mocked adapters and a green build cannot replace runtime proof.

If a required prerequisite is blocked, do not start dependent implementation or
declare the item complete. Present the blocker and ask for the relevant scope or
safety decision when needed. Planning independent future work remains possible.

## Step 4: reconcile integration contracts

| Boundary | Required acceptance focus |
| --- | --- |
| Import -> library -> reader | Stable book identity, source fidelity, direct opening and restored position |
| Swift/Flutter -> Rust | Literal options, explicit provider choice, errors and cancellation ownership |
| Rust -> native callback | Lifetime, ABI/platform identity, ordering and rejection of stale events |
| Conversion -> player | First playable audio, progressive queue, manual conversion without autoplay |
| Player -> persistence/system controls | Consistent state, seek/resume, book/chapter identity and real readiness |
| Storage -> cleanup | Retained listening audio and user data survive rebuildable-cache maintenance |
| Source -> shipped package | Correct native libraries/resources, signing and source-bound artifact receipts |

Select focused integration journeys for changed contracts. Reuse valid evidence
only when tested source/build inputs match. A later shared change may invalidate
earlier client evidence; rerun only the affected acceptance, with source identity.

For performance findings, report comparable inputs, provider/model, cache state,
hardware/toolchain, sample variability and actual end-to-end readiness. Separate
build/setup/transfer/synthesis/playback timings and overlapping intervals. Do not
derive app speed from a mock or telemetry-only test.

## Step 5: deliver through the actual repository gates

1. Use one feature branch and one PR per coherent validated change. Inspect the
   actual task definitions, run applicable checks, and stage exact paths using
   `scripts/scoped_git_index.rb`. Review both staged and unstaged scope.
2. Preserve concurrent work when updating the base. If a rebase changes the
   tested source, rerun affected checks; do not transfer success to a new SHA.
3. Commit/push scoped verified work and make completed PRs ready. Ordinary
   unfinished changes stay local; an explicit backup/publication request may
   preserve them remotely in draft, without implying readiness.
4. Check required CI for that exact head and the current base/protection policy.
   The required pre-merge gate is `PR gate`; optional checks do not automatically
   expand it. Monitor only task-authorized CI, not unrelated workflows.
5. Keep the existing `Merge eligible pull requests` workflow enabled. Its trusted
   `scripts/guarded_pr_merge.mjs` verifies eligibility and server protection.
   Merge ready work after required checks pass under the standing authorization;
   never bypass failed/pending checks, drafts or requested changes.
6. Read back actual merge state and merge SHA. An accepted API request, auto-merge
   configuration or queued merge command is not proof of delivery.
7. Update local master safely and remove only branches confirmed integrated when
   cleanup is in scope. Preserve unmerged checkpoints and unrelated work.

Full post-merge validation and publishers have separate gates. Do not publish a
release, website, model, Wiki or Hugging Face snapshot, close issues, or change
repository protections merely to complete this code audit.

## Step 6: reconcile documentation and retained evidence

1. Update current guides and architecture maps to the final implementation.
   Preserve historical reports with their source/date rather than rewriting old
   runs as if they verified the new code.
2. Verify final links, task examples and removal references. Ensure no retired
   filename remains a live setup path or packaging input.
3. Retain exact commands, exit status, test counts, skips, screenshots/reports,
   source/build identities and approved before/after measurements locally.
4. Inspect logs/screenshots before sharing: library titles, document-picker
   contents, device IDs, credentials and private filesystem paths may be present.
   Publish only necessary sanitized evidence; preserve original evidence privately.
5. Record remaining native SE1 acceptance, platform availability and dependency
   artifact blockers accurately. A physical iPhone or different runtime cannot
   close the quarantined Simulator requirement.

## Exit criteria and user-facing delivery

The final report lists reviewed scope, confirmed/corrected findings, deliberate
exclusions, rejected hypotheses, approved removals, measured improvements,
runtime acceptance and outstanding decisions. Each delivered item has its PR,
commit/merge SHA, required CI result and evidence reference.

An audit can report completed review coverage while still exposing unresolved
findings; it must not call the entire implementation complete in that state.
Stop when the authorized acceptance is established. Do not turn closure into a
new unrequested cleanup, redesign, publication or benchmark campaign.
