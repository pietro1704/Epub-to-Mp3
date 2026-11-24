---
name: ship-prs
description: Resume a session and move the open PR queue to merge - handoff, queue check, rebase, CI triage, merge.
---

# Ship the PR queue

Follow the delivery rules in `docs/agents/execution-policy.md#git-and-publication`.

1. Resume: read the pending handoff or checkpoint and the board.
2. Queue: `gh pr list --state open` for all agents; note owner, head, checks and
   dependencies. Do not touch a PR another agent pushed in the last 15 minutes.
3. Stop here if Pietro declared a release pause.
4. Rebase PRs that fell behind `master` (`gh stack sync` for stacks), push with
   `--force-with-lease`.
5. Failed checks: runner not acquired or other infrastructure -> rerun the failed
   jobs (at most 3 times); real test or lint failure -> the owning agent fixes it
   with a red-first regression test; design question -> ask Pietro.
6. Keep squash auto-merge enabled; merge green PRs at the exact head.
7. Report one digest: merged, waiting, blocked and why. Then update the checkpoint.
