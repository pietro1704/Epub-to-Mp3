# Implementation completion evidence

A task is complete when its requested behavior, relevant checks and required
acceptance are verified, and its scoped delivery state is reported accurately.
The [execution policy](agents/execution-policy.md) and
[delivery workflow](agent-workflow.md) define authorization and sequence.

Report:

- the concrete behavior or documentation changed and its owned scope;
- regression evidence, executed checks and source/build identity where relevant;
- the PR link and commit, required `PR gate` result and CI state actually observed;
- blocked, unavailable or unexecuted acceptance, including quarantined Simulator
  checks and manual validation awaiting a user result;
- merge SHA and branch cleanup only when those actions were performed and verified.

Preserve unrelated working-tree changes, open issues, PRs and alerts. Repository-
wide cleanliness, zero open issues and zero security alerts are not implicit
acceptance conditions for a scoped change. Investigate a concrete finding within
its risk and authorization; do not checkpoint incomplete work or close/dismiss
external records merely to satisfy a completion checklist.

CI monitoring is opt-in. Neither an after-push hook nor an audit script expands
task scope or proves that the current commit passed CI. Keep pending/unobserved
results explicit and do not claim completed delivery until required checks pass.
All ready PRs to `master` retain current automatic-merge authorization and trusted
helper safeguards; release/publication and issue closure have separate boundaries.
