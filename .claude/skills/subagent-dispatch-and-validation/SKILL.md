---
name: subagent-dispatch-and-validation
description: Use when a task spans multiple domains, needs a specialist's curated knowledge (TTS engines, dual-path backend, iOS/Flutter clients, CI, security, etc.), or is about to be declared "done". Routes to the right `.claude/agents/*` specialist and enforces this repo's validation gate (mise run test, CI watch, on-device confirmation for iOS/macOS) before anything is called complete.
---

# Specialist Subagents + Validation Gate

Two halves of the same habit this repo has converged on: (1) don't do
everything in the main thread — dispatch to the specialist whose curated
prompt already encodes this project's battle scars, and (2) never call
something "done" without exercising the actual validation gate for that
surface. Complements `portable-agent-pipeline` (the tool-agnostic
clarify→plan→execute→verify→critic→test→review contract) — this skill is
the concrete "how" for Epub-to-Mp3: which agent, which command, which
evidence.

## 1. Routing to a specialist

Full roster + one-line trigger lives in `.claude/agents/README.md`; a
condensed snapshot is in memory as `project_agent_inventory.md`. Don't
re-derive the roster here — read one of those two before guessing.

- Match the request to the most SPECIFIC agent's `description`, not the
  closest generic one.
- Independent, multi-domain work → one `Agent` call per domain, all in the
  SAME message (see `feedback_parallel_agents.md`,
  `feedback_parallel_debug_agents.md` — this repo's default is parallel
  fan-out for independent work, not serial investigation).
- Default to background dispatch unless the result is needed before the
  next step can be taken — a log/health read that doesn't block further
  work goes background; a design decision you're about to act on goes
  foreground.
- Pre-assign file/module ownership before dispatch whenever two agents
  could touch overlapping code. Never let two workers write the same file.
- **Trust but verify.** An agent's final report describes what it intended
  to do, not necessarily what it did — check the actual diff/output before
  repeating its claims to the user as fact.
- The pipeline-stage agents (`verification-engineer`, `qa-engineer`,
  `apple-standards-reviewer`, `pipeline-compliance-monitor`) are the
  Verifier/Critic roles from `portable-agent-pipeline` made concrete for
  this repo — reach for them instead of self-verifying non-trivial changes.

## 2. The validation gate — before calling anything done

Root-cause first: reproduce with real evidence (`grep`, `git log -p`,
`git blame`, actual log/trace reads, or a failing repro) before writing a
fix. A hypothesis without evidence is a guess, not a diagnosis.

| Surface | Gate | Never accept as proof |
|---|---|---|
| `python_app/` | `mise run test` (unit + integration + web + lint + build) | A single `pytest -k` on just the new test |
| `web/` | Same `mise run test` — vitest passing ≠ `tsc` passing | `npm run test` alone (see `feedback_web_typecheck_gap.md`) |
| Any push | `gh run watch <run_id>` until green; fix red before moving on | Assuming CI will pass because local tests did |
| iOS/macOS | Physical-device confirmation from the user | Compile success or a green XCTest run alone (see `feedback_ios_deploy_launch.md`, "Verification / Definition of Done" in `~/CLAUDE.md`) |
| Bug fix | A regression test that fails without the fix and passes with it | "The code looks right now" |

Commit per fix, not per session (`feedback_workflow.md`) — each fix gets
its own focused commit with its own regression test, so a revert doesn't
take unrelated work with it.

## Worked example

A health-monitor pass found `outcome=partial` with `chapters_failed=0` and
no explanation. Root cause came from `git log -p` on `session_logger.py`
plus reading `validate_book`'s actual return shape — not a guess — which
surfaced two independent bugs. Each got its own fix + regression test,
targeted `pytest` first, then the full `mise run test`, then its own
commit, then push + `gh run watch` to green. That loop is the default for
any bug-shaped task here, not the exception.
