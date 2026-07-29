---
name: goal-plan-execute
description: Execute non-trivial repository goals through specialist inspection, reviewed planning, focused implementation, live verification, adversarial QA, tests, and final diff audit.
---

# Goal plan execute

Use this workflow for multi-file features, user-visible fixes, parser changes,
or work spanning more than one client surface.

1. Inspect the current worktree and read project instructions before editing.
2. Split discovery into independent specialist passes with explicit ownership:
   parser/data contract, UI/state flow, and tests/runtime verification. If no
   subagent tool is available, run these passes in parallel and label them.
3. Write a short plan containing scope, non-goals, affected files, risks, and
   acceptance evidence. Review the plan against the user's exact wording before
   touching code.
4. Implement in reversible slices. Preserve existing user changes and keep
   ownership boundaries disjoint.
5. Verify the golden path using the real executable path. Treat source presence
   or a unit test as insufficient proof of runtime behavior.
6. Run an adversarial QA pass for edge cases, regressions, accessibility,
   portability, and performance. Then add or update permanent regression tests.
7. Run the project's required checks, inspect the final diff, and report what
   was executed versus what could not be run. Never claim completion from intent
   or an indirect check.

For parser/rendering work, compare source fidelity explicitly: titles, hierarchy,
HTML structure, CSS, images/resources, links, and plain-text fallback must each
have an evidence-backed acceptance check.
