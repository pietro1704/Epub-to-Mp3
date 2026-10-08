# Portable project bootstrap — Epub-to-Mp3

Use this only when a Claude session is not automatically attached to the repository. It is a locator, not a source of current implementation facts; `AGENTS.md`, `CONTEXT.md`, code, and ADRs take precedence.

Before coding, locate the live checkout and read its `AGENTS.md`, `CONTEXT.md`, relevant ADRs, nested platform instructions, and current Git status/diff. If repository access is unavailable, ask for the specific missing artifact instead of treating this brief or a prior conversation as current state.

The required product contract is local conversion through the shared Rust runtime. The migration may be incomplete: check `mise run migration:product-boundary-audit` and `mise run check:rust-migration` before asserting that a client or release path has cut over.

Use `APP_REMAINING_WORK.md` for the backlog, acceptance criteria, and recorded evidence; its status may be stale, so revalidate each item against the live checkout. Python/FastAPI, React, and HF paths may still be compatibility or migration surfaces; verify the code and task results.

Work on the requested slice only. Preserve existing changes, use the repository's relevant skill and narrowest valid verification, and report observed evidence and limitations. Ask only when a missing detail changes the goal, scope, risk, authorization, compatibility, or acceptance. Do not assume permission for builds, simulator/device actions, external writes, commits, or pushes.

For task-specific prompt wording, use `CLAUDE-MINI-PROMPT.md` only if its fields add clarity; do not repeat this brief or the repository rules in every prompt.
