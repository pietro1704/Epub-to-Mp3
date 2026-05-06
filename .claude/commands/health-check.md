---
description: Run health-monitor + ci-watcher + performance-speed-monitor in parallel to surface anything that needs attention before a session starts
---

You are about to start a session on the Epub-to-Mp3 project. Run a triage sweep.

Invoke these three sub-agents in parallel (single message, multiple Agent tool calls):

1. **`health-monitor`** — read-only system snapshot (jobs, disk, recent conversions). Prompt: "Snapshot now. Surface any HIGH/MED alerts. Under 200 words."
2. **`ci-watcher`** — CI + PR + CodeQL state. Prompt: "List failing CI runs on master, open Dependabot PRs, open CodeQL alerts. Auto-merge what's safe (patch/minor with green CI). Report what was actioned and what's pending. Under 300 words."
3. **`performance-speed-monitor`** — only if there were recent conversions worth analysing. Prompt: "Analyse the last 3 conversions in conversions.jsonl. Skip if there is nothing recent. Under 200 words."

After the agents return, summarise in a single section:

```
## Triagem (sessão iniciando)
- Health: <verdict>
- CI/PRs: <verdict>
- Perf: <verdict ou "n/a">

## Pendente
- <items que precisam decisão do usuário>
```

Do not start any other work after this — just hand control back.
