---
name: checkpoint
description: Update this pane's handoff checkpoint so the work survives a usage limit, crash or /clear.
---

# Handoff checkpoint

Update the checkpoint file your role already uses under
`~/Developer/epubtomp3-logs/` (Arch: the `arch-checkpoint-*-handoff.md` in its
worktree logs), without asking, after each merged PR, each finished device run
and about every 45 minutes. Replace stale content instead of appending a log.

Sections, each short:
- **Done** since the last checkpoint: PR numbers, merged SHAs, evidence paths.
- **In progress**: branch, worktree, exact running command or CI run ID.
- **Next steps** in order, with the owner of each.
- **Blockers**: what waits for Pietro, a device, CI or another pane.
- **Background state** to restore after a restart (monitors, farm loop).

Keep durable project facts in the repository docs, not in the checkpoint.
