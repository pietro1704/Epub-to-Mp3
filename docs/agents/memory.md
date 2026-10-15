# Agent memory configuration

Canonical project rules live in root `AGENTS.md` (a symlink to `CLAUDE.md`),
with native reader rules in `ios/EpubToMp3/AGENTS.md`. Language and runtime test
ownership lives in `CODING_STANDARDS.md`; Gitflow and native execution phases
live in `docs/agent-workflow.md`. Resolve these paths from the repository root.

The root `.ai-memory.toml` deliberately preserves `default/epubtomp3` for all
subdirectories. The remote-derived name is different and already occupied;
changing the marker could split or mix history. Use explicit workspace/project
arguments for static MCP clients. Session-aware routing requires an actual
lifecycle session identity bridge; hooks alone do not establish one.

The ai-memory-managed block and six `.agents/skills/ai-memory-*` skills are
installed together using the installed CLI's canonical assets. Refresh from
the repository root with:

```sh
ai-memory install-instructions --target CLAUDE.md --compact --skills-agent agents --skills-scope project
ai-memory doctor --json
```

Inspect installer-created backups and preserve them outside the checkout.
Keep managed block/skill text canonical. Hooks and the MCP connection already
exist in the user's Codex configuration; project routing does not require a
second MCP server or changes to credentials, approval policy or services.

Use ai-memory for cross-harness durable knowledge and advisory consolidation
preferences, not duplicated harness-private notes. `_prompts/consolidation.md`
guides English technical summaries and evidence attribution. Hardware panic
evidence is project-specific; it does not belong in the global profile.
Project rules remain authoritative over historical memory and profile defaults.

## Git ownership

Keep project-owned skills under `.agents/skills`, `.codex/skills` and
`.claude/skills`, relative Hermes skill aliases, shared hooks/settings, plans,
instruction files and `.ai-memory.toml` versioned. Local agent memory, sessions,
instruction backups, Hermes installed tools/snapshots and QA captures belong
outside the index. Root VS Code extensions/settings/tasks and the three existing
public Vite routing profiles remain shared; local overrides and secret `.env`
files are ignored. Templates contain placeholders, never credentials.

Use `mise run git:hygiene:test` to exercise this policy through Git in temporary
repositories. When correcting an already tracked artifact, inspect references
and local changes, capture its hash, then remove only its index entry and verify
the bytes remain unchanged. Ignore rules alone do not untrack existing files;
index cleanup does not remove older commits from history.

Verified baseline: ai-memory 2.6.2, 2026-10-15. Check installed `--help` and
managed assets against upstream docs before changing configuration; current
upstream installation instructions may describe a newer release.

References consulted:

- [Official OpenAI AGENTS.md discovery](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
- [Official OpenAI configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Official OpenAI skill/instruction guidance](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra)
- [ai-memory documentation](https://github.com/akitaonrails/ai-memory)
- [ai-memory profile precedence and project rules](https://github.com/akitaonrails/ai-memory/blob/main/docs/cross-project-profile.md)
