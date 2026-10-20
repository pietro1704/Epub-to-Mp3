---
name: goal-plan-execute
description: Execute non-trivial repository goals through specialist inspection, reviewed planning, focused implementation, live verification, adversarial QA, tests, and final diff audit.
---

# Goal plan execute

Use this workflow for substantial features or coordinated changes across runtime
boundaries. For a focused bug or configuration fix, use the short path in the
project diagnosing-bugs skill. Changing both production code and its regression
test does not by itself require a planning campaign.

1. Inspect the current worktree and read project instructions before editing.
2. Delegate independent questions with explicit file ownership when the scope
   needs specialist inspection. Choose affected seams rather than imposing
   parser, UI and runtime passes on every task. If delegation is unavailable,
   inspect those actual seams sequentially.
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
