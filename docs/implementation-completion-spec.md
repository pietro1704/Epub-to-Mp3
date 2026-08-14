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
3. Run `scripts/post_implementation_audit.sh --wait` for the pushed SHA.
4. Repair every failing check or security finding, then repeat from step 1.
5. Report the checked commit, validation evidence, and any external state that
   is still genuinely pending. Do not call the work complete while an Action
   or scan is pending.

## Automation

`PostToolUse` invokes `.claude/hooks/ci_watch.sh` after `git push`. The hook
runs the same audit and returns a compact result to the agent. The hook is a
safety net, not a substitute for an agent verifying its own final state.

## Scope boundaries

Closing an issue is an outcome, not a way to hide a defect. Keep an issue open
when resolving it needs product direction, external access, or a risky change;
record the precise blocker instead. Security alerts may only be dismissed when
the recorded rationale is evidence-backed; otherwise remediate and rescan.
