# Agent Inventory

One-line guide: **name** — when to invoke.

## Project agents (`/.claude/agents/`)

| Agent | When to invoke |
|---|---|
| `android-emulator-manager` | Android SDK/AVD cleanup and smallest x86_64 Flutter emulator setup on Intel Mac. |
| `architecture-mapper` | Understand where a feature lives, how modules connect, or trace a data-flow path. |
| `audio-player-engineer` | Playback issues on iOS (`AVQueuePlayer`, streaming) or Flutter (`just_audio`). |
| `audio-validator` | Reported truncation, silence, or wrong-engine audio artefacts. |
| `backend-architect` | Non-trivial dual-path (converter + server) changes that must stay in sync. |
| `book-triager` | Choosing engine / flags / settings for a specific EPUB (oversized chapters, footnotes, language). |
| `cache-storage-engineer` | `.cache/`, `.jobs/`, `output/`, `UserDefaults` persistence, or TTL/cleanup logic. |
| `ci-watcher` | Triage GitHub CI failures, CodeQL alerts, Dependabot PRs. |
| `documentation-engineer` | README, CHANGELOG, CLAUDE.md, agent definitions, docstrings, AND the GitHub Wiki (merged docs-curator + wiki-curator). |
| `epub-parser-specialist` | NCX / EPUB3 nav hierarchy, footnote handling, duplicate-chapter detection. |
| `epub-reader-ui` | Paginated reader UI, font/size controls, scroll-to-chapter on mobile clients. |
| `error-archaeologist` | Dig into conversion failures: retry chains, error_classifier patterns. |
| `error-watcher` | Real-time error sentinel across CLI, web, HF Spaces. |
| `file-picker-uploader` | Mobile file picker (`UIDocumentPickerViewController`, Flutter), upload flow. |
| `flutter-companion` | Flutter app (Linux / Windows / Android): Dart models, state, FFI, build. |
| `health-monitor` | Live job/resource health: CPU, queue depth, stall detection. |
| `hf-spaces-monitor` | HF Spaces deploy, Docker rebuild, keep-alive, Space logs. |
| `i18n-curator` | English-only enforcement in code + i18n translation strings in `web/src/i18n/`. |
| **`ios-accessibility-auditor`** | Audit SwiftUI app for VoiceOver labels, Dynamic Type, contrast, hit targets. Invoke after any UI sprint. |
| `ios-companion` | Design / scaffold new SwiftUI screens connecting to the FastAPI backend. |
| **`ios-ui-auditor`** | Audit SwiftUI app against Apple HIG and visual consistency. Invoke after layout or theme changes. |
| **`ios-widget-engineer`** | WidgetKit: home-screen / lock-screen widgets, Live Activity, `ConversionActivityAttributes`, App Group sync. |
| `mobile-coordinator` | Coordinating lockstep changes across iOS and Flutter clients. |
| `offline-cache-mobile` | Local MP3 + chapter-text cache on device: download manager, eviction, resume. |
| `performance-speed-monitor` | Analyse conversion throughput, diagnose slowness, push speed limits. |
| `release-coordinator` | Cut a release: version bumps, CHANGELOG entry, tag, CI artefacts. **Do not run in parallel with documentation-engineer on CHANGELOG.** |
| `security-auditor` | CVE sweep (pip-audit + npm audit), CodeQL alerts, supply-chain hardening. |
| `speed-benchmarker` | Reproducible chars/s benchmarks per engine, parallel vs serial comparisons. |
| **`swiftui-performance-profiler`** | Profile excessive view redraws, layout thrash, Instruments traces in the iOS/macOS app. |
| `xcode-toolchain-manager` | Xcode/iOS Simulator runtimes, CoreSimulator cleanup, destinations, and smallest compatible iPhone setup. |
| `sync-engine` | Time-based text ↔ audio sync on mobile: word highlighting, scroll tracking. |
| `telemetry-analyst` | Mine `conversions.jsonl` and `telemetry/*.jsonl` for patterns, regressions. |
| `test-engineer` | Write/expand the permanent unit + integration + UI test suite (always all 3), fixture extraction, coverage gaps. Runs LAST in the pipeline, after verification + QA sign off. |
| `tts-engine-engineer` | Edge-TTS / Piper engine internals: chunk tuning, backoff, segment integrity. |
| `ui-modernizer` | Web frontend (React/TypeScript): component styling, i18n labels, Tailwind. |
| `web-frontend-engineer` | Deep frontend work: state machine (`useConversionFlow`), SSE wiring, API client. |
| `workflow-coordinator` | GitHub Actions mechanics: skipped jobs, required-checks config, matrix. |

### Pipeline agents (analysis → execution → verification → QA → tests → commit/PR)

| Agent | When to invoke |
|---|---|
| `apple-standards-reviewer` | PRE (plan) and POST (diff) review of any iOS/macOS change against SOLID, Apple HIG, and Apple platform/API idiom. |
| `verification-engineer` | Right after implementation, before any test is written — proves the change actually works (runs it, or for iOS/macOS hands back a device checklist). |
| `qa-engineer` | After verification passes — adversarial sweep for edge cases, cross-feature regressions, UX polish, before tests are written. |
| `pipeline-compliance-monitor` | Meta-agent: audits whether a task/session actually followed this pipeline (grill → parallel delegation → stage order → PR/CI/review → P0 handling), on demand. |

## Global agents (`~/.claude/agents/`)

| Agent | When to invoke |
|---|---|
| `algo-interviewer` | Practice algorithm / data-structure interview drills (senior iOS focus). |
| `code-review-senior` | Senior tech-lead review across Swift, Python, TypeScript. |
| `commit-pr-writer` | Draft conventional-commit messages or PR descriptions. |
| `concurrency-coach` | Swift Concurrency interview drills (async/await, actors, structured concurrency). |
| `disk-janitor` | Triage disk pressure and clean up rebuildable artefacts on the dev machine. |
| `dotfiles-reconciler` | Detect and reconcile chezmoi source ↔ `$HOME` drift. |
| `flutter-mirror` | Mirror SwiftUI view changes into the Flutter companion (`flutter_app/`). |
| `interview-behavioral-coach` | Behavioral interview prep ("tell me about a time…"). |
| `ios-system-design-coach` | iOS system design interview drills (architecture, scalability). |
| `latex-academic-helper` | LaTeX edits for the Portuguese academic paper at `~/Developer/artigo mariana/`. |
| `strudel-extension-helper` | VS Code extension dev for Strudel live-coding at `~/Developer/strudel/`. |
| `swift-language-coach` | Swift language deep-dives for senior interview prep. |
| `swiftui-drillmaster` | SwiftUI interview drills and hands-on exercises. |
| `uikit-to-swiftui-translator` | Translate UIKit patterns into idiomatic SwiftUI for a UIKit-trained engineer. |
