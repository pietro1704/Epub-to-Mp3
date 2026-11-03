# Complete audit remaining TODO

Read the [execution checkpoint](execution-checkpoint.md) and
[original plan](../2026-11-03-complete-code-audit.md) first. A checked publication
task is not a claim of merge or executed acceptance. Runtime suites remain
deferred to the final campaign; existing protected automatic merge stays active.

## Resume delivery and preserve the checkpoint

- [ ] Inspect current worktrees and local changes; preserve all evidence and user data.
- [ ] Make one delivery query for #1076 and #1079–#1082; record actual merge SHAs.
- [ ] Fetch/verify master ancestry and safely refresh owned branches if required.
  Use exact expected-tip force leases; never bypass a failed lease or PR gate.
- [ ] Keep #1072 in draft. Its physical PDF test, nested mise entry and CLAUDE
  reader rule remain separate unvalidated preservation scope.
- [ ] Resume Swift from the first unfinished source item below, not from phase 1's inventory.

## Phase 1 — remaining ownership and final reconciliation

- [x] Inventory/navigation and identified documentation fixes: #1073, #1074, #1077, #1078.
- [ ] ORG-004: retain `libtest.rlib` and `log.txt` pending full consumer/reproducibility
  trace. Origins found in Git: `ef5adc170d` and `5da24a39e4`. A Flutter test uses a
  synthetic `log.txt` name, not necessarily this root artifact. No removal approved.
- [ ] ORG-005: finish exact upstream/local patch/license/refresh inventory for
  native vendored dependencies during the Rust phase. Do not split upstream code
  mechanically or delete eSpeak WAV inputs.
- [ ] Reconcile the final tree against the original census and check remaining
  active links/anchors/examples, preserving historical dates and locale content.

## Phase 2 — Swift implementation still open

Published first slices:

- [x] SWIFT-001 failed-catalog data safety + 9 native regressions (#1080).
- [x] SWIFT-002 partial playback identity/coverage + 4 regressions (#1081).
- [x] SWIFT-003 audio dot-segment containment + 3 regressions (#1079).
- [x] SWIFT-004 App Intents shared library + 7 regressions (#1082).
- [ ] Confirm their integration and run the final native campaign; no local native
  build/test or user journey has established these outcomes yet.

Next source-derived findings, not yet implemented or reproduced in runtime:

- [ ] SWIFT-005: incoming file import can replace a reader selection made while
  copying (`App/EpubToMp3App.handleIncomingURL`). Revalidate navigation identity
  after await while retaining the completed import; cover cancellation/replacement.
- [ ] SWIFT-006: iOS bookmark-creation failure becomes `Data()` in
  `LibraryImportPreparation`; the index decoder later drops that row. Propagate
  failure before successful publication/inbox cleanup; cover reload and source bytes.
- [ ] SWIFT-007: synchronous `LibraryStore.openBookFile` closes security scope on
  a mutable URL after migration. Capture/close the original URL; current known
  callers are tests, so establish product exposure before expanding the fix.
- [ ] SWIFT-008: recovery truncates ordinals with `filename.prefix(4)` in
  `BookConversionRecoveryStore`. Rust uses minimum-width `{:04}` and PDF permits
  more than 9,999 chapters/pages. Parse the complete numeric prefix before `-`;
  use tiny fixtures for 1000/10000/10001 and invalid receipt cases.
- [ ] SWIFT-009: Share Extension suggested provider filenames can discard the
  accepted PDF/EPUB extension; the inbox then ignores an apparently successful
  import. Canonicalize from accepted type and cover extensionless/`.bin` URLs,
  Data payloads, failure and unchanged bytes at the real owning seam.
- [ ] SWIFT-010: SettingsScreenController/MacSpeechModelLibraryPanel retain `self`
  across never-ending install streams. Resolve weak ownership per event and verify
  deallocation/observer termination without cancelling the client-owned install.
- [ ] SWIFT-011: `WidgetDataSync.updateNowPlaying` retains old total chapters when
  a new snapshot has nil total. Exercise the actual writer for replacement,
  same-book unknown total, known updates and clear. Keep dormant last-read wiring separate.
- [ ] SWIFT-012: widget views use literal strings despite target localization
  resources. Use existing locale keys; separately review Share Extension missing
  resources. Native presentation/VoiceOver/locales need actual final acceptance.
- [ ] Complete unreviewed Swift files, model/background transfer paths, detailed
  seek/transport, resources and app/extension/tool target membership coverage.

Hypotheses requiring further source trace and final native reproduction:

- [ ] Mac external file open may not route a fresh reader explicitly after import.
- [ ] iOS paused playback restoration may overwrite a newer session after awaits;
  compare the generation/book checks already present in the Mac path.
- [ ] Listener observers ignoring `snapshot == nil` may retain an active generation.
- [ ] Audio manifest relative paths/identity/uniqueness need a separate containment fixture.
- [ ] Reader PDF preparation does not forward parent cancellation to detached work;
  distinguish wasted work from stale presentation (existing generation checks).
- [ ] Directory-EPUB materialization limits and extreme PDF cover dimensions need
  bounded fixtures; no unrequested stress benchmark or user-book mutation.
- [ ] Last-read widget producers are not wired; audio chapter index may derive from
  reader position, and the widget's fixed skip label may disagree with preferences.
- [ ] FFI `dlopen` lifetime and inactive CloudSync scaffold require consumer tracing
  before changing ownership or removing code.

## Phase 3 — Xcode and mise

- [ ] Execute [the playbook](03-xcode-mise.md): task effects/graph, effective
  target/SDK/configuration settings, build identity, script work and tool routing.
- [ ] Preserve storage/single-job guards, device-specific Xcode selection and
  platform ownership. Ask about verified prebuilts before dependency/tool compilation.
- [ ] Keep performance claims as hypotheses until equivalent measurements exist.

## Phase 4 — shared Rust

- [ ] Execute [the playbook](04-rust.md) with one named editing owner.
- [ ] RUST-001: revalidate ambiguous plain numeric chapter selectors. The current
  predicate matches literal chapter ID OR zero-based position; explicit `position:N`
  avoids ambiguous documentation but does not fix the runtime contract.
- [ ] RUST-002: trace CLI defaults without saved preferences through runtime policy.
  `TtsPreferences::default()` has no secondary fallback, while `app_default(true)`
  configures system fallback. Establish actual backend support before changing it.
- [ ] Trace CLI book cache clearing's source-hash/input-stem targets versus current
  job-ID output ownership and user consent, without deleting real artifacts.
- [ ] Review parser fidelity/resources, FFI lifetime/ABI, providers, jobs/cancellation,
  persistence/artifacts, dependencies/vendor patches and affected clients.

## Phase 5 — Flutter

- [ ] Execute [the playbook](05-flutter.md) for state/bindings, reader/player,
  cancellation/disposal, identity, resume/offline, accessibility/locales and assets.
- [ ] Perform Linux work on Arch and obtain Windows-specific evidence. Android
  stays paused until explicit resumption; another platform cannot substitute.

## Phase 6 — final test and delivery campaign

- [ ] Reconcile every reviewed file family, exclusion, finding and delivery identity.
- [ ] Web: dependency-security regressions, lint/types, full Web tests with at most
  two workers, build and relevant real browser journeys. Metadata audit alone is insufficient.
- [ ] Native: new catalog safety, restoration, path containment and App Intent
  suites, then all required affected XCTest/UI/visible/audible journeys.
- [ ] Rust: owning crate/integration/FFI and affected consumer checks with guarded
  single-job execution and valid artifacts/prebuilt authorization.
- [ ] Flutter: owning platform analyze/tests and real client acceptance.
- [ ] Keep required SE1/iOS 15.5 acceptance blocked while Simulator is quarantined;
  preserve all other unavailable/unrun checks explicitly.
- [ ] Fix observed failures in coherent slices, update source/build identities,
  confirm exact-head gates/merges, and publish a truthful final closure report.
