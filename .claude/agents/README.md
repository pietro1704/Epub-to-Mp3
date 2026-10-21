# Project specialist inventory

Twelve canonical domain specialists and 31 compatibility names retain all 43
existing invocation paths. Select by the requested task; this inventory does
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
[history](../../docs/agents/history/specialists/README.md) retain the immutable
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

## All invocation names

Compatibility pointers load the named canonical file in the same invocation;
they do not dispatch another agent. Legacy Python, remote transport, Flutter
parity, WidgetKit, release and monitoring branches load only for their matching
requested task. Android execution stays paused under execution policy.

| Existing name | Canonical specialist | Task trigger |
| --- | --- | --- |
| [android-emulator-manager](android-emulator-manager.md) | [backend-architect](backend-architect.md) | Android SDK/AVD inventory or setup; execution stays paused until the user resumes Android and belongs on Arch. |
| [apple-standards-reviewer](apple-standards-reviewer.md) | [ios-companion](ios-companion.md) | Focused native design/diff review using Apple HIG, API idioms, actor isolation and actual layout constraints. |
| [architecture-mapper](architecture-mapper.md) | [backend-architect](backend-architect.md) | Read-only current entrypoint/import/data-flow maps with verified file:line citations and wired-vs-defined distinctions. |
| [audio-player-engineer](audio-player-engineer.md) | [audio-player-engineer](audio-player-engineer.md) | Playback resume, streaming queue, interruptions, lock-screen controls or audio/text synchronization. |
| [audio-validator](audio-validator.md) | [tts-engine-engineer](tts-engine-engineer.md) | Reported truncation, wrong-language or stitching anomalies; separate decoded/spoken evidence from duration heuristics. |
| [backend-architect](backend-architect.md) | [backend-architect](backend-architect.md) | Shared Rust conversion, FFI/client contracts, runtime mapping or explicitly requested Flutter parity. |
| [book-triager](book-triager.md) | [epub-parser-specialist](epub-parser-specialist.md) | Read-only supplied-book structure/language/size/footnote triage and verified current CLI recommendations. |
| [cache-storage-engineer](cache-storage-engineer.md) | [cache-storage-engineer](cache-storage-engineer.md) | Artifact/cache persistence, invalidation, import ownership, restart/resume, eviction or scoped disk cleanup. |
| [ci-watcher](ci-watcher.md) | [workflow-coordinator](workflow-coordinator.md) | Requested CI/PR/alert snapshot or failing-run triage; follow opt-in monitoring and exact-head merge policy. |
| [disk-janitor](disk-janitor.md) | [cache-storage-engineer](cache-storage-engineer.md) | Disk-pressure inventory and explicitly scoped cleanup using canonical storage guards and data preservation. |
| [documentation-engineer](documentation-engineer.md) | [documentation-engineer](documentation-engineer.md) | Requested repository documentation/instruction updates, truth/link review or explicitly scoped public Wiki work. |
| [epub-parser-specialist](epub-parser-specialist.md) | [epub-parser-specialist](epub-parser-specialist.md) | EPUB/PDF structure, TOC hierarchy, chapter identity, source fidelity or book-specific triage. |
| [epub-reader-ui](epub-reader-ui.md) | [epub-reader-ui](epub-reader-ui.md) | Native reader pagination, clipping, chrome, font reflow, page turns or playback-follow interaction. |
| [error-archaeologist](error-archaeologist.md) | [backend-architect](backend-architect.md) | Reconstruct one failed conversion run, its first causal error, bounded retries, provider chain and terminal outcome. |
| [error-watcher](error-watcher.md) | [telemetry-analyst](telemetry-analyst.md) | Requested bounded error snapshot or explicitly bounded monitoring; fixes need their own authorized scope. |
| [file-picker-uploader](file-picker-uploader.md) | [cache-storage-engineer](cache-storage-engineer.md) | Picker/share/open-in-place import, security-scoped ownership, cancellation and actual local or remote transfer seam. |
| [flutter-companion](flutter-companion.md) | [backend-architect](backend-architect.md) | Requested Flutter Linux/Windows/Android presentation and Rust bindings; Linux/Android checks belong on Arch, Android paused. |
| [flutter-mirror](flutter-mirror.md) | [backend-architect](backend-architect.md) | Explicitly requested parity for named behavior/revisions; preserve shared Rust logic and platform-native presentation. |
| [health-monitor](health-monitor.md) | [telemetry-analyst](telemetry-analyst.md) | One requested read-only job/resource/disk snapshot with actual identity and timestamp evidence. |
| [hf-spaces-monitor](hf-spaces-monitor.md) | [workflow-coordinator](workflow-coordinator.md) | Requested Hugging Face workflow/deploy diagnosis using current container/runtime configuration; publication/restart separate. |
| [i18n-curator](i18n-curator.md) | [web-frontend-engineer](web-frontend-engineer.md) | Requested locale-key/placeholder parity and language-policy review while preserving intentional source/fixture literals. |
| [ios-accessibility-auditor](ios-accessibility-auditor.md) | [ios-companion](ios-companion.md) | Focused native VoiceOver, Dynamic Type, contrast, reduced motion/transparency or keyboard audit with runtime limits. |
| [ios-companion](ios-companion.md) | [ios-companion](ios-companion.md) | Native UIKit/AppKit features, Apple API/HIG/a11y review, WidgetKit integration or guarded Xcode diagnosis. |
| [ios-ui-auditor](ios-ui-auditor.md) | [ios-companion](ios-companion.md) | Requested UIKit/AppKit rendered UI/HIG review, native materials, adaptive geometry and user-impact findings. |
| [ios-widget-engineer](ios-widget-engineer.md) | [ios-companion](ios-companion.md) | WidgetKit/App Intents/Live Activity changes; inspect App Group snapshots, availability, deep links and lifecycle. |
| [mobile-coordinator](mobile-coordinator.md) | [backend-architect](backend-architect.md) | Explicitly scoped cross-client Rust/FFI/binding contract parity with one shared-Rust editing owner. |
| [offline-cache-mobile](offline-cache-mobile.md) | [cache-storage-engineer](cache-storage-engineer.md) | Artifact integrity, resumable partials, restart and eviction preserving active playback and user data. |
| [performance-speed-monitor](performance-speed-monitor.md) | [telemetry-analyst](telemetry-analyst.md) | Measured conversion bottleneck analysis and bounded tuning proposals from existing comparable evidence. |
| [pipeline-compliance-monitor](pipeline-compliance-monitor.md) | [workflow-coordinator](workflow-coordinator.md) | Read-only audit of requested scope, runtime evidence, proportional regression coverage and delivery-policy compliance. |
| [qa-engineer](qa-engineer.md) | [workflow-coordinator](workflow-coordinator.md) | Independent affected-scenario review for relevant empty/failure/rapid-action/restart/accessibility and identity cases. |
| [release-coordinator](release-coordinator.md) | [workflow-coordinator](workflow-coordinator.md) | Explicit release preparation/publication scope, actual version sources, curated changelog and integrated validated SHA. |
| [security-auditor](security-auditor.md) | [security-auditor](security-auditor.md) | Scoped vulnerability, secret-handling, dependency, trust-boundary or workflow-security review. |
| [speed-benchmarker](speed-benchmarker.md) | [telemetry-analyst](telemetry-analyst.md) | Explicit reproducible benchmark with literal inputs/range, comparable cache/provider/revision and uncertainty. |
| [swiftui-performance-profiler](swiftui-performance-profiler.md) | [ios-companion](ios-companion.md) | Native layout/scroll/memory performance diagnosis from measurements; use SwiftUI-specific tools only where SwiftUI exists. |
| [sync-engine](sync-engine.md) | [audio-player-engineer](audio-player-engineer.md) | Audio-time to immutable source-anchor mapping, measured timestamps, seek/chapter drift correction and reader interruption. |
| [telemetry-analyst](telemetry-analyst.md) | [telemetry-analyst](telemetry-analyst.md) | Read-only health/error snapshots, historical performance/fallback analysis or an explicitly requested benchmark. |
| [test-engineer](test-engineer.md) | [workflow-coordinator](workflow-coordinator.md) | Behavioral regression design at the owning runtime, meaningful assertions, isolation and bounded flake reproduction. |
| [tts-engine-engineer](tts-engine-engineer.md) | [tts-engine-engineer](tts-engine-engineer.md) | Provider/model selection, Piper/system recovery, voice correctness, stitching or suspected audio truncation. |
| [ui-modernizer](ui-modernizer.md) | [web-frontend-engineer](web-frontend-engineer.md) | Requested React presentation, localization, accessible controls and rendered loading/error/empty states. |
| [verification-engineer](verification-engineer.md) | [workflow-coordinator](workflow-coordinator.md) | Verify a specific claim using the real runtime and separate build/test/app evidence from unexercised acceptance. |
| [web-frontend-engineer](web-frontend-engineer.md) | [web-frontend-engineer](web-frontend-engineer.md) | React/TypeScript UI, Rust/WASM state, reconnect/cancel/resume flows, localization or web accessibility. |
| [workflow-coordinator](workflow-coordinator.md) | [workflow-coordinator](workflow-coordinator.md) | GitHub Actions triggers/CI failures, delivery-evidence audit, regression strategy or an explicitly requested release. |
| [xcode-toolchain-manager](xcode-toolchain-manager.md) | [ios-companion](ios-companion.md) | Read-only Xcode/destination/signing diagnosis or authorized guarded packaging; preserve Simulator quarantine and installed state. |
