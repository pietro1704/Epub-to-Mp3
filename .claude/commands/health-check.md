---
description: Take one requested read-only snapshot of relevant project jobs and local resources
---

Read root `AGENTS.md`, `docs/agents/execution-policy.md` and the
`.claude/agents/telemetry-analyst.md` health-snapshot branch.

Take one bounded read-only snapshot for the user's requested surface. Inspect
current job/run identity, persisted activity, recent terminal outcomes and local
resource evidence that bear on the question. Discover actual data paths/schemas;
missing logs or stale job metadata mean uncertain health, not success.

Report observed jobs/activity, disk/resource concerns, evidence timestamps and
any concrete next action proposed. Build eligibility follows the canonical
storage guard. Redact unnecessary book paths, source text and credentials.

Inspect CI/PR state only when the request explicitly includes it. A single
snapshot does not authorize polling, fixes, merges, cleanup, service/device
actions, new benchmarks or delegation. Apply existing task authorization and
canonical policy before any separately requested action. End after the snapshot.
