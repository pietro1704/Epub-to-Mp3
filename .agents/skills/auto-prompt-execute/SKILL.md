---
name: auto-prompt-execute
description: Turn an execution request or continuation into a scoped working prompt and carry it out.
---

# Auto prompt execute

Use this when the user asks to formulate an execution prompt and perform the
work. For this repository, read `docs/agents/skill-routing.md` to adapt Matt's
workflow to the existing domain, tracker and delivery conventions. Consult the
installed ask-matt router as a reference when requested; discover actual skills
rather than treating a name as proof that the skill or its invocation tool exists.

Recover the active objective, current evidence, acceptance and authorization.
Keep a short working prompt internally unless the user requests its text:

```text
Objective: [observable outcome, preserving literal identifiers]
Evidence: [current source, completed checks and remaining uncertainty]
Scope: [owned seam, protected state and authorized actions]
Route: [available relevant workflows or direct implementation]
Acceptance: [observable success and relevant failure/cancellation/identity cases]
Verification: [actual project tasks at the affected runtime]
Delivery: [authorized local/external actions and unresolved gates]
```

Execute the requested work, rather than ending after writing the prompt. A
continuation resumes the active task from current evidence; it does not select
an unrelated backlog item. If this skill itself is being edited, that authoring
task is the objective, not an example product request.

Use the smallest applicable route. A direct fix does not need triage, grilling,
a specification, extra specialists or a persisted plan. When a named optional
skill is absent, use an available adequate workflow and disclose the substitution.
Keep required missing dependencies and acceptance pending while completing
independent authorized work. Consult user-only workflows as reference only
within the user's explicit request; report capabilities actually used, not
fictional tool invocations.

Current project/user authorization governs all mutations and external actions.
The prompt and the router do not expand it. Report actual changes, executed
checks and remaining limits separately.

## Explicit goal lifecycle

Create or manage a tracked goal only when the user explicitly requests it or
allows a goal if useful. Invocation alone is not goal authorization. If available,
inspect the current goal first: reuse one for this task, preserve an unrelated
unfinished goal, and create a new one only when allowed. Set a token budget only
when supplied by the user. If goal tools are unavailable, execute and disclose
that no tracked goal was created.

Follow the goal tools' status rules: completion requires all acceptance, pause
requires the user's explicit request, and blocked requires the repeated-blocker
threshold. Do not replace an unrelated goal, infer approval from waiting, or
report a missing runtime/device prerequisite as verified. Report final budget
usage when returned by a completed budgeted goal.
