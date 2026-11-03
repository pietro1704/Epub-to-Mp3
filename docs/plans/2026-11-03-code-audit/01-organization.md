# Phase 1: files, folders and documentation

Status: initial inventory/documentation slices integrated; follow-ups remain.
Return to the [audit overview](../2026-11-03-complete-code-audit.md).

- [x] Inventory 5,256 baseline tracked paths and generated/vendor boundaries (#1073).
- [x] Publish a minimal navigation proposal preserving existing product roots (#1073).
- [x] Correct native references, consolidation history and CLI/ingestion facts (#1074, #1077, #1078).
- [x] Preserve all candidate removals and historical/user artifacts; no structural move applied.
- [ ] Resolve ORG-004 artifact provenance and ORG-005 vendored patch ownership.
- [ ] Reconcile final-tree coverage and remaining content/link acceptance in phase 6.

See [checkpoint](execution-checkpoint.md) and [TODO](TODO.md) for exact identities.

## Outcome and entry conditions

Make the repository navigable and distinguish supported product code, supporting
tools, compatibility code, generated output and historical evidence. Keep behavior
unchanged while reorganizing. Start here before the Swift audit.

Re-read [execution policy](../../agents/execution-policy.md),
[delivery workflow](../../agent-workflow.md) and
[coding standards](../../../CODING_STANDARDS.md). Record current HEAD, branch,
status, staged changes and relevant worktrees. Preserve concurrent work. The
planning baseline is a dated observation; revalidate paths before execution.

## Source observations to revalidate

| Surface | Observed organization | Consequence for planning |
| --- | --- | --- |
| Apple | `ios/EpubToMp3/EpubToMp3/{App,Features,Shared}` | Preserve existing responsibility boundaries initially |
| Rust | `crates/`, `native/piper-runtime`, `native/vendor` | Distinguish product ownership from patched third-party sources |
| Flutter | `flutter_app/lib/{models,screens,services,state,views}` | Trace runtime and packaging consumers before moving assets |
| Documentation | `docs/adr`, `docs/agents`, `docs/research`, `docs/wiki`, `docs/consolidation`, `docs/plans` | Reuse existing categories; avoid a second documentation hierarchy |
| Root | Current contracts coexist with dated audit/resume plans | Classify by purpose and current references, not filename alone |

The root `AGENTS.md` is a symlink to `CLAUDE.md`. The Swift
[Package.swift](../../../ios/EpubToMp3/Package.swift) explicitly lists source and
test paths. [Cargo.toml](../../../Cargo.toml) declares local vendor patches.
[pubspec.yaml](../../../flutter_app/pubspec.yaml) includes Python compatibility
assets. These are active references, not evidence that the referenced content is
removable.

## Step 1: build the coverage inventory

1. Enumerate tracked paths using `git ls-files -z`; inspect untracked changes
   separately. Use `rg --files` for current source discovery. Do not recursively
   ingest ignored books, models, audio, private evidence or credentials.
2. Give every owned directory and file family a purpose and owner: application,
   shared runtime, adapter, test/fixture, tooling, generated, vendor, compatibility,
   current documentation, historical documentation or private state.
3. For generated files, record the generator and canonical input. For vendored
   sources, record upstream revision, local patch, license and regeneration path.
   For binary assets, identify whether they are build inputs or derived output.
4. Record project-owned files above the 500-line standard and responsibility
   concerns. Generated localization and unmodified third-party files are explicit
   exclusions, not automatic refactoring targets.
5. Mark uncertain ownership as `needs investigation`; do not manufacture an
   unused-file conclusion from a filename, age or zero text-search matches.

Inventory columns: `path/glob`, `owner`, `purpose`, `canonical input`, `consumers`,
`generated/vendor status`, `review state`, `evidence`, `proposed action`.
Keep operational progress in the existing local task convention. Publish only
reviewed project documentation, never raw inventories containing private paths.

## Step 2: trace path consumers

1. Search references in code, tests and Markdown, then inspect manifests and task
   expansion: XcodeGen `project.yml`, SwiftPM, Cargo manifests, `pubspec.yaml`,
   CMake/platform projects, `mise.toml`, scripts and `.github/workflows`.
2. Check implicit consumers: directory inclusion, glob patterns, target resource
   membership, dynamic plugin loading, fixture lookup, app bundle paths, CLI
   entrypoints and distribution archives. Text search alone cannot prove absence.
3. For a proposed move, establish the complete set of callers and generated
   consumers. Record platform differences and whether a source path participates
   in artifact identity or cache receipts.
4. Preserve externally visible identifiers: bundle IDs, FFI symbols, serialized
   keys, localized values, persisted filenames and public command names. Changing
   one is a compatibility change, not a cosmetic organization edit.

## Step 3: reconcile documentation before moving code

1. Map the navigation from the root README to Apple, Flutter, shared runtime,
   development, validation, architecture decisions and troubleshooting.
2. Classify each document as current contract, operational guide, accepted ADR,
   proposal or historical evidence. Add explicit dates/status when claims could
   otherwise be read as current acceptance.
3. Compare setup and runtime claims with source and actual tasks. Prioritize
   provider defaults, embedded Rust ownership, supported formats, platform
   responsibility, Xcode routing, Simulator restrictions and task side effects.
4. Resolve conflicting claims at their canonical source; link to it rather than
   duplicating policy. A historical plan cannot override current instructions.
5. Correct local wiki facts consistently in English and Portuguese. Preserve
   intended locale content; new technical documentation is English. External
   GitHub Wiki publication is a separate action, not a Markdown check.
6. Validate local targets and anchors, relevant external references, examples and
   task names. Do not execute install/build/cleanup commands merely to test a
   documented example.

Initial candidates include `APP_REMAINING_WORK.md`, `AUDIT-0.4.0.md`,
`QA_FIX_PLAN.md`, `READER_LAYOUT_RESUME_HTML_PLAN.md`, `RESUME_CONSOLIDATION.md`,
`CLAUDE-MINI-PROMPT.md` and `CLAUDE-PROJECT-BRIEF.md`. Their historical status or
retirement must be established individually. The consolidation index references
older integration checkpoints; compare its claims with actual deliveries before
editing the wording.

## Step 4: propose a minimal target structure

1. Keep product roots and current feature boundaries unless the inventory proves
   a specific navigation or ownership problem. Do not move the Apple project to
   a new root simply because it also supports macOS.
2. Prepare a move table with exact `old path -> new path`, rationale, all affected
   consumers, compatibility risk, validation and rollback strategy.
3. Separate documentation moves, source moves and deletions into reviewable
   slices. Obtain user confirmation for consequential restructuring, removed
   functionality or uncertain ownership before applying it.
4. Move one responsibility, update all verified references in the same change,
   and review the resulting source/resource membership. Do not hand-edit generated
   Xcode output as the canonical fix.
5. Check the diff for accidental behavior changes, ignored inputs becoming
   tracked, broken symlinks, case-only path collisions and unrelated formatting.

## Step 5: evaluate removals explicitly

1. Start with tracked `libtest.rlib` and `log.txt` as candidates, not confirmed
   waste. Establish provenance, consumers and reproducibility.
2. Trace compatibility Python assets and bridge users through all supported
   packaging paths before proposing removal. Lack of Apple runtime use does not
   establish lack of Flutter, release or test use.
3. Treat `native/vendor` patches and eSpeak source WAV assets as owned dependency
   inputs until proven otherwise; inspect their provenance manifests.
4. Present a deletion list with exact files, size/benefit, evidence of non-use,
   affected platforms, replacement and recovery path. Wait for confirmation for
   relevant/destructive removals, as requested by the user.
5. Delete only the approved list. Check source, tests, manifests, packaging and
   documentation again; run the checks that could detect a missing input.

Do not clean `.reports`, models, books, user audio, preferences, active caches or
retained packages under this phase. Build-cache maintenance uses its separate
guarded policy and never a generic `clean` task.

## Step 6: validate and deliver each slice

| Change | Required evidence before declaring it done |
| --- | --- |
| Documentation only | Accurate claims, valid links/anchors/examples and reviewed diff |
| Ignore/index behavior | `mise run git:hygiene:test` and exact tracked/untracked scope |
| Tooling references | Focused executable host tests; `host:workflow:test` where applicable |
| Source/resource move | Correct target membership and affected runtime/packaging checks |
| Dependency or asset removal | Consumer trace, approved list and affected packaging/runtime evidence |

Read task definitions immediately before execution. `guard:no-python-production`
only covers its actual Docker packaging scope; `check:rust-migration` reports
source/artifact readiness, not native behavior or verified binary identity.

Use scoped staging, inspect the complete diff and run required checks. Deliver a
feature branch/PR for one coherent slice, then integrate after required exact-head
CI. Do not roll unresolved moves or removals into the next phase's refactor.

## Exit criteria and first executable slice

- Inventory covers all tracked product/support surfaces, with explicit uncertain
  items and justified generated/vendor exclusions.
- Current documentation has a navigable entry path; obsolete claims are corrected
  or visibly historical, and references still resolve.
- Every applied move/removal has consumer evidence and the required acceptance.
- No unapproved deletion, functional change, private evidence publication or
  data/cache cleanup occurred.
- Remaining candidates have finding IDs and owners, without a false completion
  claim. A blocked prerequisite requires a scope decision before dependent work.

The first slice is the tracked-file/documentation inventory and the proposed
navigation/move table. Present any consequential structural decision before the
first move. The next slice corrects documentation and links; source movement and
deletion follow only when their own evidence and approval are ready.
