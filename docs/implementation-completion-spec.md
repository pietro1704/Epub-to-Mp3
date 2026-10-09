# Implementation Completion Hygiene

## Intent

Every feature and bug fix ends only after the repository and its GitHub
delivery surface are clean. Agents infer this requirement from any completed
implementation; it does not need to be repeated by the user.

## Completion contract

Before reporting an implementation as complete, verify all of the following
for the pushed commit:

1. The working tree is clean.
2. Required GitHub Actions runs for that commit have completed successfully.
   A failed or cancelled run is diagnosed and fixed before completion.
3. There are no open pull requests and no open issues. New external issues are
   triaged: fix and close reproducible defects, or leave an evidence-backed
   comment when a user decision is required.
4. Code Scanning and Dependabot have no open alerts. A security finding is P0:
   checkpoint current work, patch a known safe remediation, push it, and verify
   the resulting scan. Unknown or high-risk remediations require escalation.
5. The relevant local validation for the changed surface has passed.

## Operating loop

1. Implement and locally validate the change.
2. Commit a focused diff and push it.
3. Enable automatic merge when authorized and continue independent work.
   Do not poll CI or run `scripts/post_implementation_audit.sh --wait` by default.
4. When a failure notification arrives, inspect that run or security finding,
   repair it, and repeat from step 1.
5. Report the checked commit, local validation evidence, and pending external
   state. Verify the completion contract when final delivery is reported;
   do not call the work complete while an Action or scan is pending.

## Automation

The `CI failure diagnose` workflow handles failed CI and Release Desktop runs.
It posts a diagnostic comment on the associated PR, or opens an issue for a
master failure. Successful runs do not notify the agent. The push hook does
not monitor CI; required checks and automatic merge handle delivery while the
agent continues independent work. A failure notification triggers diagnosis
and a focused fix.

## Scope boundaries

Closing an issue is an outcome, not a way to hide a defect. Keep an issue open
when resolving it needs product direction, external access, or a risky change;
record the precise blocker instead. Security alerts may only be dismissed when
the recorded rationale is evidence-backed; otherwise remediate and rescan.
