# Collaboration retrospective controls

> **Historical record (reviewed 2026-10-21).** Dated retrospective implementation record at baseline `7e346da6d6`. “Current session”, existing branch and commit/push authorization below belong to that task. Preserve executed evidence; current operation follows [execution policy](execution-policy.md) and [collaboration operations](collaboration-operations.md).

Scope: implement all five candidates from the current session retrospective.
Baseline: `7e346da6d6`; preserve unrelated dirty files and existing runtime behavior.
Use the existing feature branch as this tooling continuation. User explicitly
authorized implementation, verification, then commit/push at the end.

| ID | Owner | Acceptance | Status |
| --- | --- | --- | --- |
| RETRO-6 | Root | Collaboration/tooling Node regressions execute in normal host preflight and the CI host gate; failure stops later checks | Verified |
| RETRO-7 | Installer specialist | Static portable installer accepts JSON bytes, verifies all baselines before writes, preserves aliases/backups and repeats without writes; actual Arch deployment | Verified |
| RETRO-8 | Doctor specialist + root | Read-only live Mac-to-Arch and local Arch probes verify supported CLI, routing and project UUIDs; malformed/missing identity fails closed | Verified |
| RETRO-9 | xcresult specialist + root | Same bundle operations serialize, independent bundles overlap, errors/cancellation propagate; existing real bundle inspection works | Verified |
| RETRO-10 | Root | Repeatable deterministic queue verification uses exact owned IDs, catches duplicate/claim/cancel behavior, leaves no own pending fixtures and invokes no model; documented short procedure | Verified |

Risks: CLI version/schema differences, remote dirty instructions/tasks, generated
string escaping, uncertain send outcomes, locks shared through path aliases.
Tests exercise these at the executable seam. The doctor stays read-only;
revalidation explicitly creates only its own bounded queue fixtures. Messages
remain untrusted data and never confer authority or launch commands.

No app build, device action, model download, new daemon/port, history migration,
remote CI monitoring or merge belongs to this task. Existing native artifacts
may be inspected through xcresulttool; that is not a new app verification.

Verification evidence is recorded below after execution. Raw output belongs in
`.reports/retro-collaboration-20261015/`, not the tracked task backlog.

## Executed evidence

- RETRO-6: `mise run preflight` executed all 13 registered suites, passing 139 tests:
  79 Ruby tests/674 assertions and 60 Node tests, no failures/errors/skips. Exact
  report: `.reports/host-workflow/20261016T013938-11797/results/report.json`.
  Real Node failure/ordered mixed-runtime fixtures prove failure propagation.
  The CI host job explicitly installs Node and runs the same aggregator with
  scoped mise tools; workflow binding is checked. Remote CI was not run/monitored.
- RETRO-7: static installer tests passed 14/14. It planned/applied 14 scoped files
  on Arch from literal JSON; repeat receipt marks all 14 unchanged. Backups are
  outside the checkout and AGENTS.md remains a symlink to CLAUDE.md. The final
  deployment updates only task-owned changes; user product edits remain separate.
- RETRO-8: Mac-to-Arch doctor passed 8 checks and local Arch passed 7, including
  the server-reported loopback database UUIDs via read-only SQLite. Fourteen
  deterministic doctor regressions passed; raw auth data is omitted from reports.
- RETRO-9: wrapper process regressions passed 11 tests/55 assertions, covering
  per-bundle exclusion, aliases, independent parallel work, timeouts, errors,
  signals and descendants. Existing real bundle summary and attachment export
  were started concurrently through the guard; one waited for the same-bundle
  lease and both exited zero. Summary retained its existing 13 passed results;
  no new app tests/builds were claimed. Six attachments exported successfully.
- RETRO-10: deterministic revalidation passed 6 transport checks on Mac and Arch,
  each using three exact fixture IDs and its own unpredictable task scope.
  Both reports say `models_invoked:false`, `ok:true`, with cleanup verified.
  It verifies transport through both role mailboxes, not agent interpretation.
  Regression cases cover wrong correlation, malformed/ambiguous receipts,
  duplicate failure, fixture-only cleanup and unavailable/capped reconciliation.

Raw receipts/logs: `.reports/retro-collaboration-20261015/`. The aggregate was
followed by a focused final Node suite after strengthening its CLI-path assertion.
Node tooling passed 60/60 locally and on Arch; no skipped cases.

Independent specialists reviewed the gate integration, static installer, doctor
and deterministic revalidation. Reported limitations are deliberate: cooperating
installer locks plus stale-byte rechecks, atomic individual file publication
without multi-file rollback, and explicit reconciliation after interrupted queue
checks. The short normal procedure lives in
[collaboration operations](collaboration-operations.md); actual-agent handshakes
are reserved for initial integration or changed interpretation requirements.
