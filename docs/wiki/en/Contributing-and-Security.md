# Contributing and security

Read [AGENTS.md](../../../AGENTS.md),
[delivery workflow](../../agent-workflow.md),
[execution policy](../../agents/execution-policy.md) and
[coding standards](../../../CODING_STANDARDS.md). Keep code/comments/logs and
technical documentation in English, except intentional localized resources/wiki pages.
Use `CONTEXT.md` and relevant ADRs; inspect current mise tasks rather than guessing.

Use one coherent feature branch/PR, preserve unrelated work, add meaningful
regression coverage and validate proportionally at the owning runtime. Relevant
errors, cancellation and book/chapter identity matter more than a mandatory count
of test tiers or specialists. Documentation-only changes need content/link checks.
Python/Ruff stay in CI; web tests start with at most two workers; native guards,
platform ownership and Simulator quarantine remain in force.

Commit/push and PR writes follow standing scoped delivery authorization after
checks. All ready PRs to `master` retain automatic-merge authorization through
the exact-head `PR gate`, current base and trusted helper; keep the merge workflow
enabled. CI monitoring is opt-in. Report the PR, commit, actual checks/CI state and
pending acceptance accurately. Releases, external publication and issue closure
remain separate task boundaries.

Security reports follow [SECURITY.md](../../../SECURITY.md): use the private
reporting channel rather than a public vulnerability issue, with impact,
reproduction and affected versions. That policy owns current scope and support;
this wiki does not redefine exclusions or claim all alerts are resolved. Preserve
credentials/private data and never publish them in fixtures, logs or reports.
