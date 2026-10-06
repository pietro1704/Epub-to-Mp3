# Delivery workflow

Use this workflow for changes that must survive review and future agent runs.

## Before implementation

For a feature larger than one focused change, write a short spec and split it
into vertical tickets. Each ticket names its dependencies, acceptance evidence,
regression test, and verification command. Keep one behavior change per branch;
do not combine feature work, refactors, dependency upgrades, and CI changes.

## During implementation

Start each bug fix with a failing regression test. Keep the implementation and
its test in the same commit when practical. Preserve unrelated local changes by
using a detached worktree instead of stashing or resetting them.

Before pushing, update the branch from `master`, run `git diff --check`, and run
`mise run preflight`. A source-level test is not evidence for a native runtime
behavior; use the platform's executable test path for native changes.

## Review and merge

Every PR has one scope and a concrete acceptance checklist. Review the complete
diff against the ticket and project standards. Do not enable auto-merge for
feature PRs. Merge only after all required checks are green, the PR is not
behind `master`, security checks are green, and the merge is visible in
`master`.

After merging, verify the branch and worktree state, then remove stale branches
only after confirming they are merged. If CI fails, inspect the failing job and
push a focused fix; never close the task on a pending or blocked check.
