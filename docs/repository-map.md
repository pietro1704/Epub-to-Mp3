# Repository map

This map explains ownership and navigation, not runtime readiness. The organization
inventory was taken on 2026-11-03 at
`bf1be38df8a60ff2efefc7399c3d4d152cb36936`: 5,256 tracked paths from
`git ls-files -z`, including four symlinks. Counts below describe that baseline,
before this map was added. Ignored books, models, audio, caches and private
execution evidence are outside the inventory.

The [six-phase audit plan](https://github.com/pietro1704/Epub-to-Mp3/pull/1072)
is a separate draft checkpoint containing unvalidated changes. This map does not
establish acceptance for that checkpoint or the later audit phases.

## Start here

| Need | Canonical entry |
| --- | --- |
| Product behavior and domain vocabulary | [CONTEXT.md](../CONTEXT.md) |
| Shared runtime and client seams | [Runtime navigation](agents/runtime-navigation.md) |
| Local setup, tasks and safety | [Execution policy](agents/execution-policy.md), then the relevant task in [mise.toml](../mise.toml) |
| Scope, regression evidence and review | [Delivery workflow](agent-workflow.md) and [coding standards](../CODING_STANDARDS.md) |
| Native Apple client | [Apple guide](../ios/EpubToMp3/README.md), [macOS validation](agents/macos-validation.md) and [reader contract](../ios/EpubToMp3/AGENTS.md) |
| Non-Apple client | [Flutter guide](../flutter_app/README.md) and [platform ownership](agents/mac-arch-collaboration.md) |
| Browser client | [Web guide](../web/README.md) and [WASM boundary](wasm-capability-boundary.md) |
| Embedded native packages | [FFI artifact contract](converter-ffi-artifacts.md) and [iOS integration](../ios/EpubToMp3/docs/converter-ffi-ios.md) |
| Local user documentation | [Wiki source index](wiki/README.md), in English and Brazilian Portuguese |
| Historical consolidation results | [Reconciled checkpoint](../RESUME_CONSOLIDATION.md) and [historical reports](consolidation/historical-reports.md) |

Guides describe their own scope and may retain dated examples. Read the canonical
contract and actual task definition before executing an example. Simulator
acceptance remains blocked by quarantine; Android work remains paused. The map
does not authorize dependency compilation, installs, cleanup or publication.

## Tracked product families

Ownership means the responsible subsystem, not a named maintainer. The table
classifies all product roots; manifests and selected entrypoints were inspected
for organization. Functional coverage is **not reviewed** until a later runtime
audit records its evidence. Keep the current paths for these families.

| Path family (baseline count) | Owner and purpose | Canonical inputs and consumers |
| --- | --- | --- |
| `ios/` (813) | Apple app, extensions, native tests, resources and project tooling | [project.yml](../ios/EpubToMp3/project.yml) defines Xcode targets; [Package.swift](../ios/EpubToMp3/Package.swift) explicitly selects Foundation sources/tests. The app uses `App/`, `Features/`, `Shared/`; XCTest, UI/device tests, widget and share extension have separate targets. |
| `crates/` (222) | Shared Rust conversion and its adapters | [Cargo.toml](../Cargo.toml) and crate manifests define `converter-core`, `converter-ffi`, CLI, server and WASM. Apple/Flutter embed FFI; Web uses WASM. |
| `native/` (2,237) | Piper runtime adapter and patched dependencies | `native/piper-runtime` is project code; `native/vendor` is dependency source/data selected by Cargo patches. See provenance below. |
| `flutter_app/` (345) | Non-Apple client, tests and platform packaging | [pubspec.yaml](../flutter_app/pubspec.yaml), platform manifests and `cmake/` select sources/assets. `lib/`, `test/`, `integration_test/`, Linux/Windows/Android packaging and generated bindings are distinct families. |
| `web/` (267) | Browser app and compatibility adapters | [package.json](../web/package.json), Vite/TypeScript configuration and `crates/converter-wasm` feed browser/Docker tasks. `src/wasm/` contains generated artifacts. |
| `python_app/` (603) | Legacy compatibility and migration oracle | [pyproject.toml](../pyproject.toml), compatibility requirements and entrypoints select `src/` and tests/fixtures. Preserve until consumers and differential acceptance are reconciled. |
| `ruby_app/` (67) | Rust HTTP client and Ruby/Rails gateways | [Ruby guide](../ruby_app/README.md), Gemfiles and gateway routes; conversion domain behavior stays in Rust. |

## Supporting families

These families are inventoried for ownership. Their behavior and every individual
document have not been audited. Tests and packaging are consumers even when a
path has no direct production import.

| Path family | Owner, input and consumers | Review/action |
| --- | --- | --- |
| `scripts/` (202) | Host tooling; mise tasks, CI, native packaging and verification invoke script entrypoints and executable regressions | Keep paths; audit affected tool behavior with its host suite |
| `tools/` (14) | Native device tooling; `DeviceWorkflow/Package.swift` selects library, CLI and tests consumed by `scripts/device-workflow.sh` | Keep; host tests cannot replace device acceptance |
| `tests/` (13), `benches/` (2), `benchmarks/` (2) | Shared audio/parity fixtures, Cargo benchmark and retained JSON reports; runtime tests and migration/performance comparisons consume them | Preserve fixture identity and dated evidence |
| `voice_samples/` (1) | Tracked README describes optional fixture/preview audio; ignored recordings are outside the census | Preserve retained samples; no audio generation, playback or cleanup |
| `config/` (1), `.cargo/` (1) | Mac storage guard and Cargo configuration; native supervisor and workspace commands consume them | Preserve enforcement; inspect before build changes |
| `.github/` (65), `.githooks/` (2) | CI, artifact production, protected delivery and local Git gates | Keep existing exact-head merge mechanism; workflow presence is not a passing check |
| `aur/` (2) | Arch packaging metadata, canonical `PKGBUILD` and derived `.SRCINFO` | Validate on the owning platform before packaging changes |
| `.agents/` (23), `.claude/` (61), `.codex/` (1), `.hermes/` (3) | Harness routing, shared skills, hooks and specialist locators; Hermes paths alias `.agents/skills/` | Preserve aliases; configuration maintenance has its own routing |
| `.vscode/` (3) | Editor task, setting and extension integration | Keep; not an authoritative runtime contract |
| `docs/` (253) | Authored guidance, dated plans and retained research/evidence | Classify by document status as below |
| Root manifests and entrypoints | `mise.toml`, Cargo manifests/lockfile, Dockerfile, `convert`, `convert-rust`, Python launchers/requirements, validation/benchmark helpers, `desktop.spec`, `shell-completion.zsh` | Keep consumer paths; Python/Web/Ruby full functional audits are outside the Swift/Rust/Flutter sequence |
| Remaining root files | Contracts, changelogs, security guidance, editor/tool/delivery settings, retained plans and the two uncertain artifacts below | Classify individually; filenames or age do not establish non-use |

The root `AGENTS.md` is a symlink to `CLAUDE.md`. The three tracked Hermes skill
aliases and this instruction alias must continue to resolve. Root launchers and
legacy platform helpers remain compatibility surfaces until their actual callers
and packaging membership have been traced.

## Generated output and dependency provenance

Generated files are reviewed through their canonical inputs. Vendored files are
not automatically unmodified: local patches remain reviewable product inputs.
None of the generation/build commands below was run for this inventory.

| Family | Canonical input / generator | Ownership and follow-up |
| --- | --- | --- |
| Apple Xcode project output | `project.yml` / XcodeGen through `xcode:generate`; Xcode project output is not tracked in this baseline | Edit the specification, then verify affected target/resource membership |
| Flutter `*.freezed.dart`, `*.g.dart` | Authored model declarations / `build_runner`, Freezed and JSON Serializable declared in `pubspec.yaml` | Generated model implementations; review models and generator versions |
| Flutter `lib/l10n/app_localizations*.dart` | ARB files and [l10n.yaml](../flutter_app/l10n.yaml) / Flutter localization generation | Generated locale output; preserve intended locale text |
| Flutter Linux/Windows `flutter/generated_*` | Flutter plugin resolution and platform generation from `pubspec.yaml`/lockfile | Generated plugin registrants and CMake lists |
| Web `src/wasm/converter_wasm*` | `crates/converter-wasm`, Cargo.lock and [build_web_wasm.sh](../scripts/build_web_wasm.sh) / matching `wasm-bindgen` | Generated JS/types/WASM; matching schema and build identity required |
| Lockfiles and `.SRCINFO` | Package manifests / the owning package manager or Arch packaging metadata generator | Derived dependency/package identity; do not split mechanically |
| `native/vendor/piper-rs/` | [UPSTREAM.md](../native/vendor/piper-rs/UPSTREAM.md): crates.io 0.2.0, upstream `d70b0970a87453f3476b5fd6cf9edf329be8b445`; MIT declared in manifest, no separate upstream license file | Local ONNX version, cancellation and configuration patches; preserve patch behavior when refreshing upstream |
| `native/vendor/espeak-rs/` | Manifest declares 0.2.0, MIT and the Piper upstream repository; `LICENSE` retained | Local clause/punctuation wrapper; exact upstream diff and refresh recipe need investigation |
| `native/vendor/espeak-rs-sys/` | `.cargo_vcs_info.json` records `d70b0970a87453f3476b5fd6cf9edf329be8b445`; [UPSTREAM.md](../native/vendor/espeak-rs-sys/UPSTREAM.md) describes the local C bridge | Rust package declares MIT; surrounding eSpeak C/bridge is GPL-3.0-or-later. Embedded eSpeak revision/license inventory and refresh procedure still need reconciliation |
| `native/vendor/sherpa-onnx-sys/` | Manifest declares 1.13.8/Apache-2.0; root Cargo patch cites upstream ZIP-security commit `1a9d234ab95567eba8c2e89873a87d70b79633e2` | Retain LICENSE and local archive/build handling; verify full patch provenance before refresh |

Dependency refresh is not simply rerunning a generator. Retrieve the recorded
upstream version, compare and reapply the reviewed local changes, retain license
material, and validate consumers before replacing any vendored tree. Missing
provenance is **needs investigation**, not evidence that removal is safe.

Tracked binary inputs include app icons, authored EPUB/audio fixtures, generated
Web WASM and eSpeak phoneme source WAVs. Their membership is established by asset
catalogs, test fixture lookup, Web generation and eSpeak build/package manifests.
An audio extension does not establish that a file is disposable listening output.
Icon generator helpers exist, but their byte-for-byte reproduction was not tested.

### Size inventory

The source/test census covered Swift, Rust, Dart, Python, Ruby, JS/TS, shell,
C/C++, JVM, PowerShell and CMake file extensions. No non-generated project-owned
source/test file in that census exceeds 500 physical lines. This does not prove
cohesive responsibilities or functional quality.

Eight generated source files exceed 500 lines: four Flutter localization outputs,
`ebook_fulltext.freezed.dart`, `job_snapshot.freezed.dart`,
`session_record.freezed.dart`, and Web `converter_wasm.js`. Exclude generated
output from mechanical splitting; review the inputs above.

Thirty-four vendored source files exceed the threshold, including locally patched
Sherpa `build.rs` (876 lines). Exclude unmodified upstream code from mechanical
splitting; establish the patch boundary before classifying local changes as
excluded. The Rust/native phase owns that review.

Large owned configuration deserves a separate responsibility review:
`mise.toml` (1,661 lines), Apple `project.yml` (685), CI `ci.yml` (603) and
`faber-integration.yml` (529). Localization resources, dependency lockfiles,
dictionaries and historical reports are separate data/documentation families.
Do not split them solely to satisfy a source-file threshold.

## Documentation status and proposed structure

| Current path | Classification and consumers | Proposed destination/action |
| --- | --- | --- |
| `README.md` and this map | Public product entry and ownership navigation | Keep paths; link the map from README |
| `CONTEXT.md`, `CODING_STANDARDS.md`, `CLAUDE.md`, `docs/agents/` outside `history/` | Current contracts and operational routing | Keep canonical paths; link rather than duplicate policy |
| `docs/adr/` | Dated architectural decisions, with section-specific supersession | Keep; the 2026-10-02 reactive-state ADR retains accepted state design but supersedes its old Edge defaults |
| `docs/wiki/`, client READMEs, Apple `docs/` | Local user/developer guidance | Keep; reconcile product facts with canonical source, in both wiki languages when affected |
| `docs/plans/`, `docs/research/`, `docs/bugs/`, dated root `docs/*.md` | Proposals, observations, experiments or dated reports | Keep provenance; status must not imply current runtime acceptance |
| `docs/agents/history/` | Explicit historical snapshots of former guides/skills/specialists | Keep historical evidence separate from active routing |
| `docs/consolidation/`, `RESUME_CONSOLIDATION.md` | Prior consolidation inventory/results and reconciled 2026-11-02 checkpoint | Keep; reconcile the index's obsolete pending claims against its checkpoint |
| `APP_REMAINING_WORK.md`, `QA_FIX_PLAN.md`, `READER_LAYOUT_RESUME_HTML_PLAN.md` | Already marked historical on 2026-10-21; referenced by backlog/bootstrap/QA reports | Keep; trace and update references before any later move |
| `AUDIT-0.4.0.md` | Read-only 2026-05-10 triage; linked by changelog/backlog | Keep historical location pending a complete reference/move proposal |
| `CLAUDE-MINI-PROMPT.md`, `CLAUDE-PROJECT-BRIEF.md` | Optional task scaffold and bootstrap locator, not historical audit results | Keep; these point to current contracts rather than establish product facts |

This first slice proposes no source or historical-document relocation. Existing
Apple/Rust/Flutter roots remain the target structure. No consequential structural
decision has been justified by the inventory alone. Any later move proposal must
name every exact old/new path, implicit packaging consumer, validation and rollback
before changing references.

## Organization findings

IDs remain stable across the audit. Observations describe the inventory baseline;
dispositions distinguish integrated documentation from open follow-up scopes.
All observations below are static; no native behavior was exercised.

| ID / class / priority | Evidence and affected consumers | Disposition / next acceptance |
| --- | --- | --- |
| ORG-001 / navigation improvement / P3 | Root README had a partial structure list; no ownership index connected product, tool, generated/vendor and historical families | Integrated in [#1073](https://github.com/pietro1704/Epub-to-Mp3/pull/1073), merge `e58dea2a0f9f99cf5f07c07fabeccfe07ac2412f`; content/link checks, independent review and exact-head PR gate passed |
| ORG-002 / confirmed documentation drift / P3 | README's iOS table named absent `InstantReaderView`/`PlayerReaderView` and placed `ConversionActivityAttributes` in `Models/`; current source and `project.yml` select `Shared/Integrations/ConversionActivityAttributes.swift` | Integrated in [#1074](https://github.com/pietro1704/Epub-to-Mp3/pull/1074), merge `7eaa70918892685e5fdf4cc2a1ffb1a9bec86437`; documentation checks/review and exact-head PR gate passed. No native behavior change or runtime acceptance claimed |
| ORG-003 / confirmed documentation drift / P3 | Consolidation index claimed a single worktree and left Flutter/optional proposals/PDF cover pending; `RESUME_CONSOLIDATION.md` reconciles deliveries through #1065 | Index now identifies the dated checkpoint and integrated responsibilities, preserves unadopted proposals and pending combined-app/iPhone/SE1 acceptance; documentation review is distinct from executing those runtime checks |
| ORG-004 / removal candidates, unproven / P3 | Tracked `libtest.rlib` (5,614 bytes) and `log.txt` (1,276 bytes); provenance, implicit consumers and reproducibility unresolved | Trace packaging/history/consumers; present exact removal, impact and recovery for user confirmation before deletion |
| ORG-005 / provenance investigation / P3 | Vendored patch/license/refresh boundaries above remain only partially documented | Establish exact upstream/local ownership and immutable refresh inputs before proposing a dependency change |
| ORG-006 / confirmed documentation drift / P3 | Ingestion notes still deferred the implemented PDF parser; CLI examples promised comma-separated selections, understated build/clear side effects and mixed Python completions with Rust | Align core/CLI boundaries, repeated selectors, explicit positions, build/clear semantics and bilingual wiki facts with current source; documented commands remain unexecuted examples |

Further organization review includes command examples, links/anchors, bilingual
facts and implicit packaging consumers. No zero-match search, passing build or
path census closes that work. Operational per-file records, commands, test logs,
delivery SHAs and pending acceptance belong in the private task/evidence record;
this published map contains reviewed repository facts only.
