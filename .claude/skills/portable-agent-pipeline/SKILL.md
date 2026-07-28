---
name: portable-agent-pipeline
description: Use when planning or executing non-trivial work (features, architecture/dependency changes, multi-file implementation, work delegated across subagents) — the proportional clarify→plan→execute→verify→critic→test→review pipeline for this repo, plus rules for when and how to fan out to parallel subagents.
---

# Portable Agent Pipeline

Full tool-agnostic contract: `docs/agent-pipeline-prompt-portable.md`. Same
contract is installed as a skill in Claude Code (repo + global), Codex CLI,
and Hermes — see `MEMORY.md` → `project_agent_inventory.md` for the
Epub-to-Mp3 specialist roster this pipeline delegates to.

```
clarify gate → Planner → Executor → Verifier → Critic/QA → Test-author → Review gate
```

Compress the loop for small/reversible changes; use it in full for features,
architecture changes, and anything touching more than a couple files.

## Clarify gate

Ask only if: a required fact is missing and can't be inferred from the repo/
conversation/defaults; the action is irreversible or costly (delete, force-
push, shared-branch merge, spend money, external send, migration); or there
are genuinely different-feature interpretations. Otherwise state one
assumption in a line and proceed.

## Stages

1. **Planner** — map affected files, short plan. Skip when the plan would be
   the same length as the diff.
2. **Executor** — implement in focused slices. Route domain work to the
   matching `.claude/agents/*` specialist (backend-architect, ios-*,
   epub-parser-specialist, etc.) — there's no generic "coder" role here.
3. **Verifier** — proves the golden path now: run it, show evidence (command
   + result, or on-device confirmation per `feedback_ios_deploy_launch.md`
   for iOS/macOS). Never writes permanent tests.
4. **Critic/QA** — adversarial pass after Verifier signs off: edge cases,
   cross-feature regressions, security/a11y/perf. Assumes the golden path is
   true and looks past it.
5. **Test-author** — permanent suite after Verifier + Critic (see Testing
   Policy in `CLAUDE.md`: Python tests never touch `.swift`, iOS tests live
   in Xcode).
6. **Review gate** — commit → push → PR → CI green → review pass before
   merge. Per `feedback_solo_auto_merge.md`, solo-dev auto-merge on green CI
   is standing authorization; a small self-contained fix can go direct.

## Parallel delegation

Fan out via the `Agent` tool only when sub-tasks are genuinely independent,
none consumes another's output, and each gets pre-assigned file/module
ownership stated explicitly before dispatch (see
`feedback_parallel_agents.md`, `feedback_parallel_debug_agents.md`).
Serialize whenever step B needs step A's output or files overlap.

## Security/perf gates

A security or performance finding mid-task is P0: checkpoint the current
step (commit what's done), fix the P0 ahead of the rest of the task, then
add a regression gate (CI/audit/benchmark) so it's caught automatically next
time. A performance claim needs a before/after number before it counts as
P0 — "feels slower" is a lead, not yet a finding.

## Anti-patterns

Six named stages for a one-line fix. Skipping the Verifier and calling a
green unit test "proof". Parallel agents with overlapping file ownership.
Auto-merging on red CI. Declaring an iOS fix done from compile/unit-test
success alone (see "Verification / Definition of Done" in `~/CLAUDE.md`).
