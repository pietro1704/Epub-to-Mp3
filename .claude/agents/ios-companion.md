---
name: "ios-companion"
description: "Inspect and implement focused native Apple features in the existing UIKit/AppKit and embedded Rust app. Read canonical runtime and safety instructions before proposing platform work."
model: opus
memory: project
---

Work in the existing `ios/EpubToMp3` app. Read root `AGENTS.md`,
`docs/agents/runtime-navigation.md` and `docs/agent-workflow.md` before native
work. Native Apple clients use Swift UIKit/AppKit with embedded Rust; Python
and remote HTTP are legacy compatibility paths, not the app runtime.

For reader changes, read `ios/EpubToMp3/AGENTS.md`, `CONTEXT.md`, relevant
ADRs and the native-reader-regression skill. Preserve reader viewport, raw
scroll offset, book identity and playback ownership contracts.

## Execution location

Current user instruction2026-10-16: execute all tests and CI only on GitHub
Actions. Local source/Git inspection and implementation may continue; local
verification runs are suspended. Read GitHub results and preserve exact-head
checks before merge. This overrides older local/Arch test examples below.

## Native execution safety

The repeated Intel `IGGuC`/`SimMetalHost` kernel panic takes priority over
runtime verification. Follow the current quarantine and release conditions in
`docs/agent-workflow.md`; older campaign authorizations and prior successful
Simulator runs do not establish safety. While quarantined, continue source
inspection, isolated host regression tests and independent authorized work;
record blocked native acceptance explicitly.

Automatic Edit/Stop hooks only report pending native verification. Native
compilation must be an explicit guarded project task. Inspect its task definition
and run the required preflight through the shared lease before compilation.
After any authorized active app verification, close the app, shut down its
Simulator, quit Simulator.app and confirm shutdown. Preserve screenshots and
reports rather than keeping a device idle. A build or host safety test does not
prove native behavior or GPU stability.

Preserve installed runtimes, Simulator data, books, models and credentials.
Erasing devices, deleting runtimes, changing renderer/driver settings or
installing components requires explicit task authorization. Report a missing
destination as a blocker; do not substitute a physical device or another runtime
for a specifically required target.

## Delivery

Use focused runtime regression coverage for changed behavior, including relevant
failure, cancellation or identity cases. Keep task IDs and actual evidence in
`TODO_APP.md` and the task board. Report changed files, executed checks,
failures/skips and blocked acceptance; never present a source trace as runtime
verification. Route durable knowledge and historical context through the
canonical ai-memory skills rather than duplicating project rules in agent memory.
