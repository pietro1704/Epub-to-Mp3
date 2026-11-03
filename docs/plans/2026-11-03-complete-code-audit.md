# Complete code audit and organization plan

Date: 2026-11-03

Status: implementation started; paused for the user's requested session handoff.
See the [execution checkpoint](2026-11-03-code-audit/execution-checkpoint.md) and
[remaining TODO](2026-11-03-code-audit/TODO.md) before resuming. Checkmarks below
distinguish delivered source work from unexecuted runtime acceptance.

## Execution checklist — 2026-11-03

- [x] Revalidate master and preserve #1072's preexisting, unvalidated scope.
- [x] Record the user's subsequent authorization to make #1072 ready and merge it through protected automatic delivery.
- [x] Publish the tracked inventory/navigation map (ORG-001, #1073, integrated).
- [x] Correct native README references (ORG-002, #1074, integrated).
- [x] Reconcile consolidation history (ORG-003, #1077, integrated).
- [x] Correct CLI/ingestion documentation and bilingual wiki (ORG-006, #1078, integrated).
- [x] Correct Crass and execute its regression/Rails checks (#1075, integrated).
- [x] Publish Minimatch/Zod corrections and new regressions (#1076, integrated; runtime checks pending).
- [x] Perform bounded Swift source reviews and publish four initial corrections
  with native regressions (#1079–#1082; merge and native execution pending).
- [x] Save this checkpoint, reviewed findings and next-session TODO.
- [ ] Finish phase 1 ownership/provenance follow-ups and final reconciliation.
- [ ] Finish phase 2 Swift review, remaining corrections and native acceptance.
- [ ] Execute phase 3 Xcode/mise audit.
- [ ] Execute phase 4 shared Rust audit.
- [ ] Execute phase 5 Flutter audit on its owning platforms.
- [ ] Execute phase 6 final runtime campaign and evidence/delivery reconciliation.

The user's latest sequence is implementation first and runtime suites at the end,
without CI monitoring. Existing server protections and automatic merge remain;
no protection bypass is authorized by this checklist. Source checks and written
tests are not executed acceptance. No automatic local continuation is scheduled.

## Objective and sequence

Review the project's organization, documentation, correctness, maintainability,
performance and build quality. Work in this order, one bounded change at a time:

1. Organize files, folders and documentation.
2. Audit the native Swift clients.
3. Audit Xcode and mise within the Swift work, before Rust.
4. Audit the shared Rust runtime and its consumers.
5. Audit Flutter.
6. Reconcile coverage, evidence, delivery and remaining work.

The initial overview was published before the detailed playbooks were prepared.
Diagnosis, proposed execution and observed acceptance remain separate.

## Detailed playbooks and execution status

| Order | Playbook | Current status |
| --- | --- | --- |
| 1 | [Organization and documentation](2026-11-03-code-audit/01-organization.md) | Inventory and identified documentation corrections integrated; ownership/provenance follow-ups retained |
| 2 | [Native Swift](2026-11-03-code-audit/02-swift.md) | Partial static review; four corrections published; native tests deferred and required Simulator acceptance blocked |
| 3 | [Xcode and mise](2026-11-03-code-audit/03-xcode-mise.md) | Planned; no performance baseline measured |
| 4 | [Shared Rust](2026-11-03-code-audit/04-rust.md) | Planned; dependency and client acceptance gates apply |
| 5 | [Flutter](2026-11-03-code-audit/05-flutter.md) | Planned; Arch/Windows evidence and Android resumption are separate |
| 6 | [Coverage and delivery](2026-11-03-code-audit/06-coverage-delivery.md) | Checkpoint/TODO recorded; full coverage and final runtime reconciliation pending |

Each playbook identifies inspected source facts, investigation steps, execution
slices, verification routes, approval points and exit criteria. Revalidate them
against the execution commit. Source inspection for planning is not a complete
audit and does not establish that a suspected defect affects users.

Resume from the first unchecked item in the checkpoint/TODO, not from the original
inventory. Keep changes coherent and branches current; independent implementation
slices may progress while protected automatic integration completes, as requested
by the later execution instruction. Dependent work still needs its source base.
Preserve blocked acceptance rather than substituting another runtime.

## 1. Organization and documentation

Inventory production code, tests, fixtures, resources, generated files, vendored
dependencies, compatibility surfaces and historical documents. Before moving a
path, record its current location, proposed destination, purpose, consumers and
validation requirements.

Preserve the established boundaries initially: Swift uses `App/`, `Features/`
and `Shared/`; Rust uses `crates/` and `native/`; Flutter uses `flutter_app/`.
Consolidate navigation between READMEs, architecture contracts, decisions,
development guides and tests. Correct obsolete links, commands and claims, and
separate current guidance from historical plans.

Root-level historical plans, `libtest.rlib`, `log.txt`, and Python assets included
by Flutter are investigation candidates, not proven unused content. Trace source,
manifests, packaging, CI and documentation consumers before proposing deletion.
Present relevant removals with exact paths and impact for user confirmation.

## 2. Swift

Review startup and import, library and persistence, EPUB/PDF reading, playback,
conversion/FFI, settings, widgets and extensions in that order. Include native
tooling, tests and resources in the coverage inventory.

For each flow, inspect correctness, concurrency, cancellation, stale callbacks,
book/chapter identity, memory, filesystem behavior, error recovery, accessibility,
localization and responsiveness. Assess duplication and responsibility boundaries
without splitting files merely to reduce their size.

Preserve direct opening into the reader, explicit playback initiation, reading
position, retained offline audio and provider policy. A confirmed bug needs a
reproduction and a regression at the affected native seam.

## 3. Xcode and mise

Treat [project.yml](../../ios/EpubToMp3/project.yml) as the generated Xcode
project's source. Inspect effective settings for each target, SDK and Debug/Release
configuration before changing flags.

Review optimization, incremental compilation, linking, debug symbols, warnings,
concurrency diagnostics, signing and packaging scripts. Measure build turnaround,
application performance and binary size separately. Investigate always-running
scripts and unnecessary Rust recompilation. Compare no-change, single-Swift-file
and resource-change builds under equivalent conditions.

Review [mise.toml](../../mise.toml) and its nested configuration for inheritance,
fixed/moving versions, platform-specific tools, task dependencies and implicit
installation. Generic install or cleanup tasks are not automatic prerequisites.

## 4. Rust

Start with `converter-core`, then `converter-ffi`, CLI/WASM/server consumers and
native/Piper integration. Cover document fidelity, malformed input, resource
limits, voice selection, fallback, jobs, progress, cancellation, caches,
persistence and artifact integrity.

At the FFI boundary, inspect memory ownership, pointer validity, callback lifetime,
threads, errors and ABI compatibility. Review dependencies, vendored patches and
compilation profiles. Shared behavior stays in Rust; changes require verification
of affected clients as well as the owning crate.

## 5. Flutter

Review state composition, embedded Rust bindings, asynchronous work, subscription
disposal, library, reader, player, conversion, resume and offline storage. Verify
contract parity, localization, accessibility, dependencies and shipped assets.
Evaluate compatibility bridge removal only after tracing all consumers.

Use the existing `flutter:analyze` and `flutter:test` tasks where applicable.
Linux verification belongs on Arch. Android remains paused until explicitly
resumed; Windows needs platform-specific evidence.

## 6. Coverage and delivery

Maintain an inventory of reviewed modules/files, justified exclusions, findings
and pending checks. Separate confirmed bugs, hypotheses and improvements. Each
finding records severity, evidence, impact, proposed scope and acceptance.

Deliver a coherent correction through reproduction, focused implementation,
regression verification, complete diff review, a scoped PR, required CI and merge.
Finish and integrate one item before starting the next. Blocked checks remain
explicitly pending; a successful build is not runtime acceptance.

## Approval and execution boundaries

- Confirm relevant deletions, removed functionality, compatibility or architecture
  changes, and destructive actions with the user before execution.
- On Mac, ask about a source/platform-matched verified prebuilt before compiling
  any dependency, runtime, library or tool. Final app targets follow the existing
  task authorization and guarded build route.
- Preserve the storage guard and one-compiler-job rule. Use the existing storage
  preflight and safe cleanup path; never weaken limits for speed.
- Preserve the Simulator quarantine. Required SE1/iOS 15.5 reader acceptance
  remains blocked; a physical iPhone cannot substitute for that target.
- Select Xcode per command: 26.3 for the physical iPhone 16e, the documented legacy
  toolchain where required. Preserve global selection and platform ownership.
- Preserve books, models, preferences, offline listening audio, useful artifacts,
  evidence, unrelated work and the root `AGENTS.md` symlink.
- Python, Web and Ruby enter the organization and dependency inventory. Their
  full functional audits are not implied by the Swift/Rust/Flutter sequence;
  validate affected consumers when shared behavior changes.
- Publication of this document does not authorize model/runtime downloads,
  external documentation publication, releases, services or device actions.

## Publication checkpoint

The initial read-only inspection started from `bf1be38df8` on `master`. The user
then explicitly requested commit/push of the plan and pending checkout changes,
followed by detailed phase planning and another commit/push.

The first checkpoint also preserves the previously uncommitted `CLAUDE.md`
reader-opening rule, `ios/EpubToMp3/mise.toml` entry and
`PhysicalPDFJourneyTests.swift`. The native PDF test has not been executed in
this planning task. The user subsequently explicitly authorized making #1072
ready and merging the combined preservation scope. The earlier draft hold is
superseded; runtime acceptance remains pending. Use protected automatic merge
and retain the final validation TODOs.

## Canonical references

- [Execution policy](../agents/execution-policy.md)
- [Delivery workflow](../agent-workflow.md)
- [Coding standards](../../CODING_STANDARDS.md)
- [Domain contracts](../../CONTEXT.md)
- [Runtime navigation](../agents/runtime-navigation.md)
- [Native reader instructions](../../ios/EpubToMp3/AGENTS.md)
- [macOS validation](../agents/macos-validation.md)
- [Mac/Arch ownership](../agents/mac-arch-collaboration.md)

The initial inventory and navigation proposal were integrated as ORG-001.
Resume from the first unchecked checkpoint/TODO item. The complete six-phase
audit and final runtime acceptance are not marked completed by this plan.
