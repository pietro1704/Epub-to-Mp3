---
name: goal-plan-execute
description: Deliver repository changes with focused inspection, proportional planning, regression verification and final diff review.
---

# Goal plan execute

Follow the current user scope and the repository's canonical instructions.
For a small, clear task, inspect the relevant files, implement directly, run
the focused checks and review the final diff. Do not require a plan document,
a specialist sequence or delegation merely because several files change.

For work with independent seams or material uncertainty, write a short plan
naming the outcome, ownership, risks and acceptance evidence. Delegate only
an independent implementation/inspection or a review whose value justifies
its cost. Give each delegate bounded context and disjoint editing ownership.
Keep native compilation serialized through the existing guard.

Preserve unrelated changes. Implement the smallest complete behavior slice
and add meaningful regression coverage at the affected runtime. Reproduce
the failure before the fix when feasible; record when this was not done.
Check relevant failure, cancellation and identity cases rather than running
every role or test category for every change.

Use the smallest authorized verification that proves the requested outcome.
Real-app acceptance requires the affected real app; static checks and tests
supplement it. When the user owns manual validation or requests static-only
verification, respect that scope and report runtime acceptance as pending.
Documentation/configuration-only edits need focused static checks, not a
native build or broad suite unless they expose a concrete runtime risk.

Review the complete final diff for correctness and regressions. For parser
or rendering changes, compare the affected source fidelity (labels, hierarchy,
markup, resources, links or fallback) explicitly. Preserve proven behavior.
Report executed checks, unresolved limits and delivery state accurately.
Follow canonical Git/PR authorization and CI policy; pushing does not request
CI monitoring, merging or publication.
