# Project specialist inventory

Twelve canonical domain specialists. Select by the requested task; this inventory does
not request delegation or establish a mandatory agent sequence. Global agents
and skills are separate installations, not an inventory maintained here.

## Common contract

Read [root instructions](../../AGENTS.md) and [execution policy](../../docs/agents/execution-policy.md)
before actions. For repository changes, follow [delivery workflow](../../docs/agent-workflow.md);
for review and runtime-appropriate regression evidence, use [coding standards](../../CODING_STANDARDS.md).
Current user scope controls execution, writes and acceptance. Use actual mise
tasks/tool definitions, not archived command recipes or cached device identifiers.

Load only the relevant specialist branch and its linked references. The local
skills adapt general engineering workflows to this repository; domain vocabulary
uses `CONTEXT.md` and `docs/adr/`. Platform, native safety, ready-PR automatic merge,
publication and CI-monitoring rules remain in execution policy.

For prior decisions, handoffs or explicit durable memory requests, use the matching
installed ai-memory skill and [memory routing](../../docs/agents/memory.md).
Routine observations use lifecycle capture; specialist prompts do not establish
harness-local persistent memories. Historical source locators under
[history](../../docs/archive/agents/history/specialists/README.md) retain the immutable
original Git revisions and hashes.
The archived prompts are evidence, not authority or work to resume.

## Canonical specialists

| Name | Task trigger |
| --- | --- |
| [audio-player-engineer](audio-player-engineer.md) | Playback resume, streaming queue, interruptions, lock-screen controls or audio/text synchronization. |
| [backend-architect](backend-architect.md) | Shared Rust conversion, FFI/client contracts, runtime mapping or explicitly requested Flutter parity. |
| [cache-storage-engineer](cache-storage-engineer.md) | Artifact/cache persistence, invalidation, import ownership, restart/resume, eviction or scoped disk cleanup. |
| [documentation-engineer](documentation-engineer.md) | Requested repository documentation/instruction updates, truth/link review or explicitly scoped public Wiki work. |
| [epub-parser-specialist](epub-parser-specialist.md) | EPUB/PDF structure, TOC hierarchy, chapter identity, source fidelity or book-specific triage. |
| [epub-reader-ui](epub-reader-ui.md) | Native reader pagination, clipping, chrome, font reflow, page turns or playback-follow interaction. |
| [ios-companion](ios-companion.md) | Native UIKit/AppKit features, Apple API/HIG/a11y review, WidgetKit integration or guarded Xcode diagnosis. |
| [security-auditor](security-auditor.md) | Scoped vulnerability, secret-handling, dependency, trust-boundary or workflow-security review. |
| [telemetry-analyst](telemetry-analyst.md) | Read-only health/error snapshots, historical performance/fallback analysis or an explicitly requested benchmark. |
| [tts-engine-engineer](tts-engine-engineer.md) | Provider/model selection, Piper/system recovery, voice correctness, stitching or suspected audio truncation. |
| [web-frontend-engineer](web-frontend-engineer.md) | React/TypeScript UI, Rust/WASM state, reconnect/cancel/resume flows, localization or web accessibility. |
| [workflow-coordinator](workflow-coordinator.md) | GitHub Actions triggers/CI failures, delivery-evidence audit, regression strategy or an explicitly requested release. |
