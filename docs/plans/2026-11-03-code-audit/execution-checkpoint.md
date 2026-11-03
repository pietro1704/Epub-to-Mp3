# Complete audit execution checkpoint

Date: 2026-11-03. Session stopped at the user's request after finishing the
in-progress Swift source slices. This records observed source/publication state,
not completion of the six-phase audit or current runtime acceptance.

Start with the [updated original plan](../2026-11-03-complete-code-audit.md) and
[remaining TODO](TODO.md). Revalidate PR state once when resuming; the snapshot
below is not a live status feed.

## Execution decisions

- Implement the six phases in order; use SOLID only for demonstrated seams.
- The latest user direction defers runtime suites to the end. Regressions are
  written now; source review, syntax/metadata and whitespace checks remain distinct.
- Keep protected automatic merge and exact-head PR gates. Do not monitor CI,
  disable protections, or infer a merge from PR creation.
- No new local execution is scheduled. Resume only after a new user request/event.
- The user subsequently explicitly authorized making #1072 ready and merging
  it, superseding the earlier draft hold. Its preexisting CLAUDE rule, nested
  mise entry and physical PDF journey are included in that authorization;
  their runtime validation remains pending. Preserve protected automatic merge.
- Merge administration does not resume the paused six-phase implementation.

## Delivered and published slices

`Integrated` means the merge identity was confirmed. `Published` means source and
regressions were pushed; native/Web acceptance and merge remain pending unless
separately recorded. Ready PRs use the existing automatic-merge workflow.

| Scope | PR | Published source | Integration at checkpoint |
| --- | --- | --- | --- |
| ORG-001 repository inventory/map | [#1073](https://github.com/pietro1704/Epub-to-Mp3/pull/1073) | `5937b7dfb0206809eed815f949e0b594295a2071` | Integrated: `e58dea2a0f9f99cf5f07c07fabeccfe07ac2412f` |
| ORG-002 native README references | [#1074](https://github.com/pietro1704/Epub-to-Mp3/pull/1074) | `95761109ae521bcc44fd14a9e22d68956c41d690` | Integrated: `7eaa70918892685e5fdf4cc2a1ffb1a9bec86437` |
| SEC-001 Crass 1.0.8 and actual sanitizer regression | [#1075](https://github.com/pietro1704/Epub-to-Mp3/pull/1075) | `4f717d35ffce62ff8225fffa6b6978cd65cd1a01` | Integrated: `a2bf0c7ed62f2528d5b0fea843ec7ecfb19b2f75` |
| SEC-002 Minimatch/Rimraf/Glob and Zod | [#1076](https://github.com/pietro1704/Epub-to-Mp3/pull/1076) | `9ef6b90e352b0595fdf7a1218b9fe8b311744369` | Integrated: `dc12d4da6769c63bdffe4b4971624f26395988ca`; runtime acceptance pending |
| ORG-003 consolidation index | [#1077](https://github.com/pietro1704/Epub-to-Mp3/pull/1077) | `bf09c1417064f28d104da07bc5bb70074cdf3693` | Integrated: `0d570a758d400b3652b59ab86b258e593c912ea2` |
| ORG-006 ingestion and CLI examples | [#1078](https://github.com/pietro1704/Epub-to-Mp3/pull/1078) | `776e9152d71dfbc94416994e4c2696976dc51874` | Integrated: `5f57172bdd46ffc6bab3d4eeebac80a679834deb` |
| SWIFT-003 dot-segment audio paths | [#1079](https://github.com/pietro1704/Epub-to-Mp3/pull/1079) | `187d777286fa8e3a97a6aeb45645aed5986e18f3` | Published, OPEN |
| SWIFT-001 catalog load failure/data protection | [#1080](https://github.com/pietro1704/Epub-to-Mp3/pull/1080) | `fd29a1816cf6e99c3b1e0d4ca25ce67b6bd358c4` | Published, OPEN |
| SWIFT-002 restored coverage/text offsets | [#1081](https://github.com/pietro1704/Epub-to-Mp3/pull/1081) | `c7577acd86ad8fcd4f7cc81895e350aebdfe669e` | Published, OPEN |
| SWIFT-004 App Intents shared catalog | [#1082](https://github.com/pietro1704/Epub-to-Mp3/pull/1082) | `20d4f0bb1786e7331001d6590845fba11c5e4667` | Published, OPEN |

The Web slice replaces vulnerable Minimatch 10.2.6 with scoped 11.0.4 overrides,
updates Rimraf to 6.1.4/Glob 14.0.3/path-scurry 3, and updates preexisting vulnerable
Zod 4.3.6 to 4.6.7 within the consumer's accepted range. A global Minimatch override
was rejected because Glob 13 expects matching internals removed in version 11.

## Evidence actually obtained

- Baseline inventory: 5,256 tracked paths, 24 directory roots and four symlinks.
  Eight oversized generated source files and 34 vendored source files were
  classified separately. This is organization coverage, not functional coverage.
- Documentation source/consumer review, local destinations and scoped diffs were
  checked. Independent reviews corrected misleading cache targets and a stale
  migration reference before publication. No documented destructive command ran.
- Before runtime tests were deferred, Crass's actual Rails sanitizer regression
  failed with 1.0.7 and passed with 1.0.8 (2 tests, 5 assertions after the fix).
  Full Rails: 6 tests, 15 assertions, zero failures/errors/skips. The required
  local host preflight passed all 18 suites. Pure Ruby package checksum verified;
  no native dependency compilation or global gem mutation was needed.
- Web lock-only resolution, syntax/format/JSON and metadata-only npm audit passed.
  That audit reported zero vulnerabilities in the candidate lockfile. It does
  not prove GitHub alert closure or executed compatibility. Web regressions,
  lint/types/build and broad preflight remain unrun after the latest direction.
- Four Swift fixes received complete owned-diff and independent static review;
  native tests were added, but compilation/XCTest/visible/audible acceptance did
  not run. Fixture data uses unique defaults/temp roots. Library persistence
  success tests retain the writer's existing WidgetCenter reload behavior.
- CI was not watched or polled. Later delivery queries requested PR identities
  only. Server gates remain in force; pending/stale branches need revalidation.

## Swift scope and required final selectors

| ID | Source behavior corrected | Native suite written, not executed |
| --- | --- | --- |
| SWIFT-001 | An undecodable catalog cannot authorize index overwrite, successful inbox cleanup, or orphan bookmark/fulltext pruning; legitimate empty catalogs remain usable | `EpubToMp3Tests/LibraryCatalogRecoverySafetyTests` (9 new methods) |
| SWIFT-002 | Restored partial conversion keeps `chapterIndexBase`, `sourceChaptersTotal` and matching `textOffset`; foreign jobs do not donate identity | `EpubToMp3Tests/RustPlaybackRestorationTests` (4 new methods) |
| SWIFT-003 | Whole `.`/`..` sanitized IDs cannot resolve to the audio root/parent or alias a normal book directory | `EpubToMp3Tests/LocalAudioArtifactStoreTests` (3 new methods in ArtifactFailureIdentity tests) |
| SWIFT-004 | Resume/OpenBook intents read the same App Group catalog as LibraryStore, retaining standard-domain pending commands | `EpubToMp3Tests/AppIntentLibraryScopeTests` (7 new methods) |

The bounded static passes covered selected startup/document/library services,
conversion/FFI/playback/offline seams, settings/configuration/integrations,
widget/share-extension sources and corresponding XCTest files. They do not cover
every Swift file. Root reader inspection covered viewport-transition and content-
surface ownership plus selected loading/cancellation call sites; full reader,
resource-fidelity and view/accessibility coverage remains open. Detailed coverage
lists and raw evidence remain local in the retained worktrees.

## Retained evidence and resumption safety

Local evidence directories are under their corresponding worktrees:
`.reports/audit-org-20261103/`, `.reports/audit-org-002-20261103/`,
`.reports/audit-org-003-20261103/`, `.reports/audit-org-006-20261103/`,
`.reports/security-crass-20261103/`, `.reports/security-minimatch-20261103/`,
`.reports/audit-swift-20261103/`, and `.reports/audit-checkpoint-20261103/`.
Use `git worktree list` to locate them; do not remove evidence or inferred caches.
Machine-specific paths and the local TODO stay out of this published checkpoint.

Before resuming, inspect worktrees/status, make one delivery query, fetch master,
verify merge ancestry and refresh each owned pending branch using an exact
expected-tip lease when necessary. Preserve concurrent changes and keep one
editing owner for Rust. Do not restart the inventory or reapply old snapshots.

The final campaign still requires native macOS journeys and the original reader
SE1/iOS 15.5 target. Simulator remains quarantined, so that acceptance is blocked;
a physical iPhone cannot replace it. Xcode 26.3 is selected per command for the
physical iPhone 16e; legacy routing/global selection are preserved. Dependency,
runtime, library or tool compilation on Mac still needs the source/platform-
matched prebuilt question. Apply storage guards and one compiler job. Flutter
Linux/Android ownership stays on Arch; Android is paused and Windows needs its
own evidence. No model download, release or external Wiki publication is implied.
