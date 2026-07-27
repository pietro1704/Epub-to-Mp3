# Portable Agent Pipeline Prompt

Reusable in any project, and with any agentic tool (Claude Code, Codex CLI,
Cursor, or a second-LLM collaborator like Hermes). Drop this into the
project's `AGENTS.md` (or `CLAUDE.md` / equivalent) — it's tool-agnostic by
design. Anchoring it in `AGENTS.md` specifically is intentional: both Codex
and Cursor already treat that file as the canonical portable contract, so
the same text works without rewriting per tool.

Based on: Anthropic's "Building Effective Agents," Claude Code subagent
orchestration guidance, OpenAI Codex CLI's official best-practices doc,
Cursor's official agent best-practices + Plan Mode, and Fabio Akita's public
writing on AI-assisted engineering discipline.

---

## 1. Clarify only when it's genuinely ambiguous — not every time

Before acting on a request, ask clarifying questions **only if at least one
of these is true**:

- A required parameter is missing and cannot be inferred from the repo,
  the conversation, or a sane project default.
- The action is **irreversible or costly**: deleting data, force-pushing,
  merging to a shared branch, spending money, sending something externally,
  a schema/data migration.
- There are **multiple plausible interpretations that lead to materially
  different outcomes** — not just different implementation details, but
  different features.

If none of those hold, **do not ask** — state the assumptions you're
proceeding under in one line, then act. Asking on an already-clear request
is a real cost (it's the top complaint against over-eager agents in both
the research and in daily use); silently guessing on a genuinely
underspecified one is worse. Pick the side the evidence is actually on: gate
on uncertainty, not on habit.

For anything non-trivial (a feature, an architecture change, multi-file
work), default to **plan-first**: write the plan, state it back, let the
human correct it before code exists — cheaper to redirect a paragraph than
a diff. For a request that's already unambiguous and small, just do it.

## 2. Pipeline: Planner → Executor → Verifier → Critic → Test-author → Review gate

This is the standard "generator-verifier" / "evaluator-optimizer" pattern,
not a bespoke invention — use it so it transfers cleanly to any tool or
teammate:

1. **Planner** (analysis) — map the affected code, produce a short plan.
   Skip this for changes small enough that the plan and the diff would be
   the same length.
2. **Executor** (iteration/execution) — implements the plan. Domain
   specialists own domain work; there is no single generic "coder" role.
3. **Verifier** — proves the change works, right now, for its golden path.
   Runs it, exercises the real path, shows evidence. Does NOT write
   permanent tests. If the target can't be run locally (e.g. it needs a
   device/environment the agent doesn't have), it hands back a concrete
   checklist instead of guessing "looks right."
4. **Critic / QA** — adversarial pass, only after the Verifier signs off.
   Hunts for what the plan didn't consider: edge cases, cross-feature
   regressions, UX/accessibility gaps. Does not re-check the golden path —
   assumes it's true and looks past it.
5. **Test-author** — writes the permanent suite **after** Verifier + Critic
   both pass. For any user-facing change, write unit + integration +
   end-to-end/UI tests together, not a subset — a change that touches
   behavior a user can see needs a test at the layer a user would notice
   it break. (If your practice leans test-first/TDD instead — a legitimate
   and often stronger default — write the test alongside or before the
   Executor step; either order is fine as long as all three test kinds
   exist before merge, none get skipped, and "verification" never becomes
   an excuse to defer testing indefinitely.)
6. **Review gate** — commit → push → PR (never straight to the shared
   branch for anything non-trivial; a small, self-contained fix is exempt
   and can go direct) → CI must run and pass → an automated review pass
   (AI or human) comments on the PR before merge.

Keep the pipeline proportional to the change. A one-line fix does not need
six named roles invoked in sequence — that's accidental complexity the
pipeline exists to avoid, not create. Reserve the full sequence for
features, architecture changes, and anything touching more than a couple
of files.

## 3. Parallel delegation — only when it's actually safe

Fan work out to parallel agents/subagents only when:

- The sub-tasks are **genuinely independent** — none consumes another's
  output.
- Each agent gets **pre-assigned ownership of specific files/modules** so
  two agents never write the same file. Assign this explicitly before
  dispatching, don't let it emerge.
- You state the parallelism explicitly (which sub-tasks, how many agents)
  — most tools serialize by default and require you to ask for concurrency.

Serialize whenever step B needs step A's output, or when the affected files
overlap. Parallelism has a real cost (separate context per agent) — don't
reach for it as a default, reach for it when the independence is real.

## 4. Security and performance findings are P0 — handled without losing context

A security or performance regression found mid-task is top priority, but
"top priority" means:

1. Finish and checkpoint the step currently in progress (commit what's
   done) — don't abandon mid-edit, that's how context and half-finished
   work get lost.
2. Fix the P0 immediately, ahead of the original task's remaining steps.
3. Treat it as a gate, not a one-off scramble: a security/performance
   finding should fail CI (audit tools, benchmark regression checks) so
   the next occurrence is caught automatically, not re-discovered by hand.
4. A performance claim needs a number behind it (before/after measurement)
   before it's treated as P0 — "feels slower" is a lead to investigate, not
   yet a P0.

## 5. Compliance check (optional, periodic)

On demand, or after a batch of work, audit against sections 1–4 using only
observable evidence — git log, PR history, CI runs, which test files
changed with which source files. Name the specific deviation with evidence
("tests were added three commits after the fix, not before/alongside" is
a finding; "seems fine" is not an audit). Don't grade code quality here —
that's the Critic's job; this only grades whether the *process* ran as
specified.

## 6. Don't over-build the pipeline itself

The two failure modes to watch for are opposite and both real: skipping
verification/testing under time pressure, and building an elaborate
multi-agent ceremony for changes that don't need it. Simplicity is a
stated design goal in Anthropic's own agent guidance, not just a nice-to-
have — favor composing a small number of clear roles over inventing a new
named stage for every project.
