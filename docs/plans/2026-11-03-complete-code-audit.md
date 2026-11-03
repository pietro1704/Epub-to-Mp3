# Complete code audit and organization plan

Date: 2026-11-03

Status: planning only. The user explicitly requested this plan as a versioned
Markdown document. Saving and publishing it does not start the audit, authorize
removals, or establish runtime acceptance.

## Objective and sequence

Review the project's organization, documentation, correctness, maintainability,
performance and build quality. Work in this order, one bounded change at a time:

1. Organize files, folders and documentation.
2. Audit the native Swift clients.
3. Audit Xcode and mise within the Swift work, before Rust.
4. Audit the shared Rust runtime and its consumers.
5. Audit Flutter.
6. Reconcile coverage, evidence, delivery and remaining work.

Each phase will have a separate step-by-step playbook after this initial plan is
published. Diagnosis, proposed execution and observed acceptance remain separate.

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
this planning task. Its publication is a preservation checkpoint, not validated
product delivery; keep the combined PR in draft until that scope is resolved.

## Canonical references

- [Execution policy](../agents/execution-policy.md)
- [Delivery workflow](../agent-workflow.md)
- [Coding standards](../../CODING_STANDARDS.md)
- [Domain contracts](../../CONTEXT.md)
- [Runtime navigation](../agents/runtime-navigation.md)
- [Native reader instructions](../../ios/EpubToMp3/AGENTS.md)
- [macOS validation](../agents/macos-validation.md)
- [Mac/Arch ownership](../agents/mac-arch-collaboration.md)

The first execution task is the inventory and concrete organization proposal,
starting with documentation. No audit phase is marked completed by this plan.
