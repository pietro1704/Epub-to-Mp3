# Project agent workflow adapter

This repository uses the canonical [AGENTS.md](../AGENTS.md),
[execution policy](agents/execution-policy.md),
[delivery workflow](agent-workflow.md) and
[coding standards](../CODING_STANDARDS.md). This adapter is a navigation aid,
not a second policy to paste into global instructions.

For a clear task, inspect the current implementation, branch/status/diff and
acceptance, implement one complete slice, verify it and review the complete
owned diff. For material uncertainty, write a short private dependency and
acceptance list. Ask only when missing information changes scope, compatibility,
risk or authorization. A plan document or specialist sequence is optional.

Use installed skills by their actual descriptions. Matt-style domain exploration,
tracer bullets, meaningful red/green evidence and deep-module review are useful
techniques when they answer the task's question. Locally:

- `CONTEXT.md` and relevant `docs/adr/` define domain terms and decisions;
- `mise.toml` and current scripts define executable tasks; inspect them before use;
- one coherent feature branch/PR is the delivery unit, including small fixes;
- ai-memory is the cross-session continuity store under
  [memory routing](agents/memory.md); routine activity is captured by hooks;
- keep local plans/handoffs and private overlays outside published diffs.

Select only relevant specialists. Delegate independent work only within current
instructions and available capacity, with explicit disjoint ownership; serialize
dependencies and native compilation. A role's report is evidence to inspect,
not permission to skip acceptance or automatically write a commit.

Tests may precede or accompany implementation. Exercise the owning runtime,
including relevant failure/cancellation/identity cases; avoid source scans or toy
reimplementations that cannot detect the regression. Documentation needs focused
static checks. Runtime claims require observed runtime evidence.

Current execution policy owns native guards, Simulator quarantine, platform
ownership, exact-head PR gate, automatic merge and opt-in CI monitoring. Findings
do not authorize unrelated repairs, benchmarks, model downloads, service changes,
releases or issue closure. Report an unresolved risk precisely rather than
inventing a universal P0 checkpoint or all-repository cleanup loop.

Global Matt skills remain a separately reviewed installation scope. Project
adaptation does not rewrite them or assume missing routes/tools are installed.
