---
name: portable-agent-pipeline
description: Execute repository changes with proportional planning and acceptance evidence.
---

# Portable agent pipeline

Follow `docs/agents/execution-policy.md` and `docs/agent-workflow.md`.
Read the affected runtime's navigation and `CODING_STANDARDS.md`.

Inspect the current branch, diff and relevant architecture. For reported
failures, reproduce before implementing when feasible. Implement the smallest
complete slice and verify at the affected runtime. Review the final diff; use
an independent reviewer when risk or uncertainty warrants it. Report actual
evidence and gaps.

Use a short plan for material uncertainty or independent work. Delegate bounded
tasks with explicit ownership when authorized and useful; keep dependent work
sequential. Add regression coverage at the failing seam during the work.

Canonical policy governs native execution, Git delivery, CI, merge and
publication. Evaluate out-of-scope findings before expanding the task.
