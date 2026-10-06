# On-demand streaming priority + TOC download Implementation Plan

> For Hermes: use subagent-driven-development skill to implement this plan task-by-task.

Goal: make “play from here” prioritize the requested chapter in the remote/SSE conversion path, and add a per-chapter download action inside the player TOC.

Architecture: keep EPUB chapter identity as the source-of-truth across reader, TOC, bookmarks, search, bootstrap, and backend prioritization. Only translate to playable-list indices at the player boundary via InstantReaderIndexMapper. For the remote path, extend the existing /api/convert submission + job persistence flow with a lightweight priorityChapterIndex hint stored on the job dict and consumed by the server conversion scheduler.

Tech Stack: SwiftUI, Swift unit/snapshot tests, FastAPI/Python job persistence, SSE job snapshots, existing DownloadManager and InstantReaderIndexMapper.

---

## Current context and validated assumptions

1. There is no existing automatic “download whole book” in the remote streaming path.
   - `BookOpenView.startAudioBootstrap(startChapterIndex:)` starts conversion/streaming so audio can arrive over SSE.
   - The explicit whole-book download is already opt-in via existing download flows.

2. `_persist_job` preserves arbitrary job keys.
   - `python_app/src/_server_job_helpers.py:20-67` saves the entire `job_data` dict via `job_manager.save_job(job_id, job_data)`.
   - It only trims `events` and `_raw_log`; it does not schema-filter unknown keys.
   - Therefore a new persisted hint like `priorityChapterIndex` is viable.

3. The index-space split is already real and must stay explicit.
   - EPUB index: zero-based, dense over `fulltext.chapters`.
   - Playable index: zero-based, filtered over `snapshot.playableChapters`.
   - `PlayerReaderView` already documents this at `ios/EpubToMp3/EpubToMp3/Views/PlayerReaderView.swift:190-205` and uses `InstantReaderIndexMapper` for translation.

4. Remote bootstrap currently ignores the requested start chapter when submitting to `/api/convert`.
   - `BookOpenView.startAudioBootstrap(startChapterIndex:)` accepts the requested zero-based chapter.
   - But the remote branch just calls `waitForBackendThenBootstrap()` with no parameter threading.
   - Then `bootstrapAudio(client:)` submits conversion through `APIClient.submitConversion(...)` with no start/prioritization field.

5. TOC currently supports jump only.
   - `ios/EpubToMp3/EpubToMp3/Views/TocDrawer.swift:76-135` renders each row as a plain button with `onJump(index)`.
   - No per-row menu/callback exists yet.
   - Existing download UX is elsewhere (`PlayerReaderView` overflow + `DownloadManager`).

---

## Files likely to change

Backend Python:
- Modify: `python_app/server.py`
- Modify: `python_app/src/_server_job_helpers.py`
- Modify: `python_app/tests/test_server_conversion.py`
- Modify or create: `python_app/tests/test_server_atomic_persistence.py`

iOS Swift:
- Modify: `ios/EpubToMp3/EpubToMp3/Services/APIClient.swift`
- Modify: `ios/EpubToMp3/EpubToMp3/Models/JobSnapshot.swift` (only if exposing the new hint on the client is useful; otherwise omit)
- Modify: `ios/EpubToMp3/EpubToMp3/Views/BookOpenView.swift`
- Modify: `ios/EpubToMp3/EpubToMp3/Views/TocDrawer.swift`
- Modify: `ios/EpubToMp3/EpubToMp3/Views/PlayerReaderView.swift`
- Modify: `ios/EpubToMp3/EpubToMp3/Services/DownloadManager.swift` only if a new single-chapter public API is needed

Swift tests:
- Modify: `ios/EpubToMp3/EpubToMp3Tests/InstantReaderIndexMapperTests.swift`
- Create: `ios/EpubToMp3/EpubToMp3Tests/BookOpenViewPriorityTests.swift`
- Create: `ios/EpubToMp3/EpubToMp3Tests/TocDrawerTests.swift`
- Optionally modify: `ios/EpubToMp3/EpubToMp3Tests/PlayerReaderToolbarSnapshotTests.swift`
- Optionally modify: `ios/EpubToMp3/EpubToMp3Tests/JobSnapshotTests.swift` only if the wire model changes

---

## Proposed backend contract

Add an optional form field to `POST /api/convert`:
- `priority_chapter_index`

Semantics:
- Value is EPUB zero-based chapter index.
- Omit field when there is no explicit priority.
- Server persists it as `job_data["priorityChapterIndex"]`.
- Conversion order becomes:
  - requested chapter first
  - then later chapters to end
  - then wrap to chapters before the requested one
- This is a prioritization hint, not a chapter-range filter.
- Existing `chapterProgress[].index` contract stays unchanged.

Do not introduce playable-index semantics anywhere in the backend.

---

## Task 1: Add failing backend tests for priority persistence and ordering

Objective: prove the server accepts, persists, and consumes a `priority_chapter_index` hint without changing existing chapter identity semantics.

Files:
- Modify: `python_app/tests/test_server_conversion.py`
- Modify or create: `python_app/tests/test_server_atomic_persistence.py`

Step 1: Add a persistence regression test
- Create/extend a test that builds a job dict with `priorityChapterIndex` and runs the persistence path.
- Assert the saved payload still contains the custom key after `_persist_job(...)` / load round-trip.

Suggested assertions:
- `saved["priorityChapterIndex"] == 7`
- unrelated existing keys remain unchanged

Step 2: Add a conversion-order test
- Find the helper/function in `server.py` that enumerates chapters for remote conversion.
- Add a test that passes chapters `[0,1,2,3,4]` with `priorityChapterIndex=3`.
- Expected order: `[3,4,0,1,2]`.

Step 3: Add bounds/invalid-input tests
- Negative index => ignored, original order preserved.
- Out-of-range index => ignored, original order preserved.
- Missing field => original order preserved.

Step 4: Run targeted Python tests
Run:
- `pytest -v --tb=short python_app/tests/test_server_conversion.py`
- `pytest -v --tb=short python_app/tests/test_server_atomic_persistence.py`

Expected:
- new tests fail before implementation

---

## Task 2: Implement backend priority threading

Objective: accept the new form field, persist it on the job, and apply it to chapter scheduling.

Files:
- Modify: `python_app/server.py`
- Possibly modify: `python_app/src/_server_job_helpers.py` only if comments/docstrings need updating

Step 1: Extend `/api/convert` input handling
- Add optional request/form parsing for `priority_chapter_index`.
- Parse as int only when provided.
- Normalize invalid values to `None`.

Step 2: Persist the hint on the job dict
- When creating or updating the in-memory job, write:
  - `job_data["priorityChapterIndex"] = normalized_value`
- Persist via existing `_persist_job(job_id, ...)` flow.

Step 3: Apply the hint at the chapter-order source of truth
- Locate the remote conversion chapter iteration path in `server.py`.
- Reorder the candidate chapters by wrapping around from the prioritized EPUB index.
- Keep `chapterProgress[].index` values unchanged.
- Do not renumber chapters.
- Do not filter chapters.

Step 4: Defensive behavior
- If the hint is invalid or absent, preserve existing order exactly.
- If some chapters are already completed, apply prioritization only to the remaining workset while preserving their original EPUB indices.

Step 5: Re-run targeted Python tests
Run:
- `pytest -v --tb=short python_app/tests/test_server_conversion.py`
- `pytest -v --tb=short python_app/tests/test_server_atomic_persistence.py`

Expected:
- PASS

---

## Task 3: Add failing iOS tests for remote bootstrap threading

Objective: prove `BookOpenView` forwards EPUB zero-based priority into remote submission instead of dropping it.

Files:
- Create: `ios/EpubToMp3/EpubToMp3Tests/BookOpenViewPriorityTests.swift`
- Possibly modify: `ios/EpubToMp3/EpubToMp3/Services/APIClient.swift` only after tests exist

Step 1: Add a narrow APIClient options test
- Test that `APIClient.ConvertOptions` can carry an optional priority field.
- Prefer testing the request-body builder if it is factored out; otherwise add a tiny helper to make this testable.

Step 2: Add a bootstrap threading test
- Assert the remote bootstrap path passes `startChapterIndex` through to the conversion submission options.
- The value must remain EPUB zero-based.

Step 3: Add a restart regression test
- Simulate a second “play from here” request with another chapter index.
- Assert the later request overwrites the earlier priority hint for the new submission.

Step 4: Run targeted Swift tests
Suggested command (adapt to existing mise task if present):
- `mise run mac:build`
- or the project’s existing Xcode/macOS unit-test invocation for `EpubToMp3Tests`

Expected:
- new tests fail before implementation

---

## Task 4: Implement iOS remote bootstrap priority submission

Objective: thread the requested EPUB index from `startAudioBootstrap(startChapterIndex:)` into `APIClient.submitConversion(...)`.

Files:
- Modify: `ios/EpubToMp3/EpubToMp3/Services/APIClient.swift`
- Modify: `ios/EpubToMp3/EpubToMp3/Views/BookOpenView.swift`

Step 1: Extend `APIClient.ConvertOptions`
- Add optional field:
  - `var priorityChapterIndex: Int? = nil`

Step 2: Serialize the new form field
- In `submitConversion(...)`, append multipart field:
  - `priority_chapter_index`
- Only when the option is non-nil.

Step 3: Thread the value through `BookOpenView`
- Update `waitForBackendThenBootstrap()` to accept the requested chapter index.
- Update `bootstrapAudio(client:)` to accept the same value.
- Build `ConvertOptions` with `priorityChapterIndex = startChapterIndex`.

Step 4: Keep the embedded path unchanged semantically
- Embedded already uses `startIndex` directly when building the synthesis order.
- Do not refactor it unless needed for clarity.

Step 5: Re-run targeted Swift tests
- Run the new priority tests plus existing mapper tests.

Expected:
- PASS

---

## Task 5: Add failing TOC tests for per-row download action

Objective: specify the new TOC affordance without breaking jump behavior or index-space rules.

Files:
- Create: `ios/EpubToMp3/EpubToMp3Tests/TocDrawerTests.swift`
- Possibly modify: `ios/EpubToMp3/EpubToMp3Tests/PlayerReaderToolbarSnapshotTests.swift`

Step 1: Add row action visibility test
- For a row whose chapter has `downloadUrl`, assert the TOC exposes a download action.

Step 2: Add disabled/unavailable-state test
- For a row with no `downloadUrl`, assert download is disabled or hidden according to the chosen UX.
- Prefer disabled with explanatory label if that matches current app conventions.

Step 3: Add callback payload test
- Assert the TOC download callback emits EPUB zero-based index, not playable index.

Step 4: Preserve jump behavior
- Assert tapping the row body still calls `onJump(index)` with EPUB zero-based index.

Step 5: Optional snapshot test
- If the row menu changes visible chrome materially, add/update a snapshot.

---

## Task 6: Implement TOC row menu and player download wiring

Objective: add a per-chapter TOC download action wired into the player’s existing download infrastructure.

Files:
- Modify: `ios/EpubToMp3/EpubToMp3/Views/TocDrawer.swift`
- Modify: `ios/EpubToMp3/EpubToMp3/Views/PlayerReaderView.swift`
- Modify: `ios/EpubToMp3/EpubToMp3/Services/DownloadManager.swift` only if needed

Step 1: Extend `TocDrawer` API
- Add an optional callback such as:
  - `let onDownload: ((Int) -> Void)?`
- Keep callback argument in EPUB zero-based index.

Step 2: Add a row-level menu affordance
- Use a trailing menu/button on each row instead of changing the primary tap target.
- Avoid making the whole row a context-menu-only interaction.
- Preserve one-tap jump as the main action.

Step 3: Determine download availability from snapshot
- For fulltext-driven rows, compute `audioReady` exactly as today.
- Download action should only be active when the corresponding snapshot chapter has a `downloadUrl`.

Step 4: Wire callback in `PlayerReaderView`
- Pass `onDownload` into `TocDrawer`.
- Resolve the EPUB index to the matching `JobSnapshot.Chapter` / download URL.
- Delegate to `DownloadManager`.

Implementation note:
- If `DownloadManager` only exposes `enqueueAll(from:baseURL:)`, add a minimal public single-chapter API instead of abusing the whole-book path.
- Prefer a focused addition like `enqueueChapter(snapshot:chapter:baseURL:)` or equivalent.

Step 5: Surface progress minimally
- Reuse existing progress UI if possible.
- Do not expand scope into a new full TOC progress subsystem unless needed.

---

## Task 7: Strengthen index-space regression coverage

Objective: prevent future EPUB/playable index drift across the new behavior.

Files:
- Modify: `ios/EpubToMp3/EpubToMp3Tests/InstantReaderIndexMapperTests.swift`
- Possibly modify: `ios/EpubToMp3/EpubToMp3Tests/JobSnapshotTests.swift`
- Modify: `python_app/tests/test_server_conversion.py`

Step 1: Extend mapper coverage
- Add a test showing a TOC download callback for EPUB index 2 maps to the correct snapshot chapter even when playable chapters are sparse.

Step 2: Add bootstrap contract test
- Assert that remote priority uses EPUB zero-based index identical to `BookOpenView.startAudioBootstrap(startChapterIndex:)`.

Step 3: Add no-renumbering backend assertion
- Ensure backend prioritization changes order only, not `chapterProgress[].index` identity.

---

## Task 8: Verify end-to-end

Objective: confirm the feature works in code paths and does not regress existing player/reader behavior.

Files:
- No new files required unless verification reveals a missing regression test

Step 1: Run focused Python tests
- `pytest -v --tb=short python_app/tests/test_server_conversion.py`
- `pytest -v --tb=short python_app/tests/test_server_atomic_persistence.py`

Step 2: Run focused Swift tests
- `InstantReaderIndexMapperTests`
- `BookOpenViewPriorityTests`
- `TocDrawerTests`
- any touched snapshot/UI tests

Step 3: Run broader project verification
- `mise run test`

Expected:
- full suite green before any commit/push

---

## Risks and tradeoffs

1. Biggest risk: mixing EPUB index with playable index
- Mitigation: keep every new callback and backend field in EPUB zero-based space.
- Translate only at the player queue boundary via `InstantReaderIndexMapper`.

2. Risk: server chapter-order logic may exist in more than one helper path
- Mitigation: locate the real source-of-truth iteration path before editing.
- Add tests around the helper actually used by `/api/convert` jobs.

3. Risk: TOC UI can accidentally degrade one-tap navigation
- Mitigation: keep row tap as jump; put download behind a trailing menu/button.

4. Risk: single-chapter download API in `DownloadManager` may tempt larger refactors
- Mitigation: add the smallest public API necessary; no download-queue redesign.

---

## Open questions to resolve during implementation

1. Should `priorityChapterIndex` be exposed back to clients in `JobSnapshot`?
- Default answer: no, unless a concrete UI/debug need appears.

2. Should the TOC action download one chapter or “download from here onward”?
- Based on current scope refinement, default to one chapter only.

3. When reattaching to an existing job, should a new “play from here” mutate the remote job priority mid-flight?
- Likely yes only if the server still has substantial remaining work.
- If mid-flight reprioritization is costly, stage 1 can limit the hint to new submissions and leave reattach unchanged, but document it explicitly.

---

## Suggested commit slices

1. `test(server): cover priority chapter persistence and ordering`
2. `feat(server): prioritize requested chapter in remote conversion order`
3. `test(ios): cover remote bootstrap priority threading`
4. `feat(ios): pass priority chapter index to convert API`
5. `test(ios): cover toc download action and index semantics`
6. `feat(ios): add per-chapter download action to player toc`

---

## Verification checklist

- [ ] Remote “play from here” submits EPUB zero-based chapter priority.
- [ ] Backend persists `priorityChapterIndex` and preserves arbitrary keys.
- [ ] Remote conversion starts with the requested chapter, then wraps.
- [ ] Existing chapter identity (`chapterProgress[].index`) is unchanged.
- [ ] TOC row tap still jumps correctly.
- [ ] TOC download action emits EPUB zero-based index.
- [ ] Download action only enables when chapter audio is actually downloadable.
- [ ] Full tests pass.
