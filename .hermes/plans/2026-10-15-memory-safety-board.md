# Memory and native safety configuration

Parent: TOOL-20261015-MEMORY-SAFETY in TODO_APP.md. Owner: Codex.

| ID | Depends on | Acceptance | Status and evidence |
| --- | --- | --- | --- |
| MEM-1 | Existing marker/hooks | Canonical routing, stable project scope and managed skills | Verified: installed CLI 2.6.2 assets; doctor resolves default/epubtomp3; scope unchanged; no reported capture problem |
| MEM-2 | MEM-1 | Consistent languages, runtime tests, Gitflow and memory attribution | Verified: canonical rules/document review; preflight uses master; consolidation and panic pages read back; global profile unchanged |
| SAFE-1 | MEM-2 | Block native compilation with active Simulator/Metal host; document phase ordering | Verified host seam: 7 tests, 46 assertions, zero skips; live read-only preflight and repository preflight passed; task definitions parsed; native execution deliberately not performed |

Scope is configuration/documentation/tooling. Prior product changes remain outside
this delivery. Host tests prove the guard decisions and master preflight routing,
not GPU stability, application behavior, or enforcement over arbitrary processes.
The preflight snapshot supplements the existing cooperative lease; callers still
own phase ordering. Two stale episodic lint findings were retained.
