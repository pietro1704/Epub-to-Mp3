---
name: subagent-dispatch-and-validation
description: Delegate authorized specialist work and verify each delegate's evidence.
---

# Specialist dispatch and validation

Use `.claude/agents/README.md` to select a specialist when authorized delegation
and curated domain knowledge or independent work materially help the task.

Give each delegate the objective, relevant context pointers, constraints,
acceptance criteria and explicit file/module ownership. Run independent tasks
concurrently and dependent tasks sequentially. Keep native work under the shared
execution guard.

Inspect actual changes and command output before adopting a delegate's claims.
Resolve conflicting findings against current source and canonical instructions.

Follow `docs/agents/execution-policy.md`, `docs/agent-workflow.md` and the
affected runtime's validation instructions for checks and delivery. Report
unexercised acceptance as pending.
