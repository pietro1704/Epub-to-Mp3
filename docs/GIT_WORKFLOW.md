# Git and PR workflow

[Execution policy](agents/execution-policy.md) owns delivery authorization,
merge safeguards and publication boundaries. [Delivery workflow](agent-workflow.md)
owns the implementation and review sequence.

1. Inspect the branch, status and relevant diff; preserve unrelated work and
   private overlays. Use one feature branch from current `master` and one PR
   for a coherent change, including small fixes.
2. Complete focused checks and requested app acceptance, then review the owned
   diff. Keep incomplete work local. Stage explicit scope rather than all files.
3. Commit, push the feature branch and create/update its PR within the standing
   authorization. Record the commit and PR link.
4. Apply the execution policy's exact-head `PR gate`, up-to-date base and trusted
   merge-helper checks. Ready PRs targeting `master` have standing automatic-merge
   authorization; drafts, conflicts, requested changes and unverified heads
   remain blocked. Keep repository auto-merge and its merge workflow enabled.
5. Monitor CI only when authorized. Report pending or unobserved CI accurately;
   pushing a branch does not establish a passing gate or completed delivery.

When rebasing an owned feature branch, follow the policy's expected-tip
`--force-with-lease` procedure and verify the remote tip. Never force-push
`master`. After an authorized merge, verify the merge SHA and integrated branch
identity before cleanup; preserve other work.

Hugging Face `main`, website publication, release tags and service restarts are
separate publication actions. A local Git remote or push mapping does not prove
synchronization, deployment success or authorization to publish. Inspect the
current publishing workflow when publication is explicitly requested; do not
reuse the old direct-push recipes from this guide's historical snapshot.
