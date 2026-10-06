# Issue tracker: GitHub

Issues and PRDs for this repository live as GitHub issues. Use the `gh` CLI for all operations.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body "..."`. Use a heredoc for multi-line bodies.
- **Read an issue**: `gh issue view <number> --comments`, also fetching labels.
- **List issues**: `gh issue list --state open --json number,title,body,labels,comments` with appropriate `--label` and `--state` filters.
- **Comment on an issue**: `gh issue comment <number> --body "..."`.
- **Apply or remove labels**: `gh issue edit <number> --add-label "..."` or `--remove-label "..."`.
- **Close**: `gh issue close <number> --comment "..."`.

Infer the repository from `git remote -v`; `gh` does this automatically inside this clone.

## Pull requests as a triage surface

**PRs as a request surface: no.**

Set this to `yes` only if external PRs should enter the same triage queue as issues.

## Skill routing

When a skill says to publish to the issue tracker, create a GitHub issue. When it says to fetch a relevant ticket, run `gh issue view <number> --comments`.

## Wayfinding operations

Used by the `wayfinder` skill. A map is one issue labelled `wayfinder:map`; child tickets are linked GitHub sub-issues or, where unavailable, task-list entries carrying `Part of #<map>`.

- Child labels are `wayfinder:research`, `wayfinder:prototype`, `wayfinder:grilling`, or `wayfinder:task`.
- Represent blockers with GitHub native issue dependencies. Where unavailable, use `Blocked by: #<n>` in the child body.
- Claim a ticket with `gh issue edit <n> --add-assignee @me`.
- Resolve a ticket by commenting with the result, closing it, and adding the decision/context pointer to its map.
