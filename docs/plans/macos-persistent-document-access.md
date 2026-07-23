# macOS Persistent Document Access Implementation Plan

> **For Claude:** Read this file before changing the repository. Continue from the current working tree; do not reset, checkout, clean, pull, merge, commit, or push unless the human explicitly asks for that exact action.

**Goal:** Make the macOS app request access to user-selected documents only once, while keeping app-owned cache and imported-book data inside the app container so normal launches do not trigger macOS Documents-folder privacy prompts.

**Architecture:** User-selected files are accessed under a balanced security-scoped scope only during import or one-time migration. The original file is preserved. The app copies imported EPUB/PDF data into its own Application Support directory and persists a bookmark to that durable copy. App-owned audiobook downloads also move out of `~/Documents` on macOS and remain in Application Support.

**Tech Stack:** SwiftUI shell, UIKit/TextKit reader, Foundation `URL` security-scoped bookmarks, XcodeGen, XCTest, macOS host tests, generic iOS/macOS builds.

---

## User requirement

The user said, in informal PT-BR:

> `quero q nao peca permissao "app pode acessar dados de documentos/etc" toda vez com app mac. deve pedir 1x só`

Interpretation:

- The app must not ask for access to Documents/Downloads or other external user data on every macOS launch/open.
- The app may ask for consent when the user first chooses a document.
- The app must reuse app-owned data and persisted authorization afterward.
- A new prompt is acceptable only when the user chooses a new resource, an old legacy bookmark is invalid/revoked, or the user explicitly requests relocation/re-import.
- The implementation must not bypass macOS consent or grant arbitrary filesystem access.

## Verified repository context

Repository root:

`/Users/pietropugliesi/Developer/Epub-to-Mp3`

Apple project:

`/Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3`

Project tooling:

- Use `mise` for XcodeGen/Xcodebuild and project tasks.
- Do not invoke globally installed Python/Node/Xcode tooling when a `mise` command is available.
- The repository has `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES` and `GCC_TREAT_WARNINGS_AS_ERRORS: YES`.
- Local Simulator/CoreSimulator runs are unsafe by default on this Intel MacBook Pro 2018 with 8 GiB RAM. Prefer macOS host tests and generic iOS builds; do not boot a simulator unless explicitly authorized.
- Code, comments, docstrings, logs, and print statements in the repository must be English.
- Every production code change needs a test update in the same turn.
- Do not touch secrets, `.env`, credentials, tokens, sessions, logs, caches, or state databases.

Current branch/status context:

- Branch: `hermes/epub-mp3-prompt-optimized-reader`
- The working tree already contains a large, authorized architecture/migration change from the previous task.
- The tree is not clean and must not be reset or normalized.
- `git diff --check` was verified successfully after the current changes.
- No commit, push, reset, merge, pull, or history rewrite has been performed.

## Root cause discovered

There were two independent access paths that could cause repeated macOS permission prompts.

### 1. App-owned cache incorrectly used Documents on macOS

`DownloadManager.audiobooksRoot()` in:

`ios/EpubToMp3/EpubToMp3/Features/Offline/Services/DownloadManager.swift`

previously used:

```swift
FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
```

and created `Documents/Audiobooks`.

`EpubToMp3App.runCacheEviction()` runs cache eviction on app launch. The eviction path scans `DownloadManager.audiobooksRoot()`. Therefore the app touched the user's Documents folder on every launch even though audiobook cache is app-owned data.

`FlickerProbe.swift` also references the Documents directory, but only when launched with `-uiTestFlickerProbe`; production launches leave that probe disarmed. It was not the primary launch-time cause.

### 2. macOS library entries retained external original files

`LibraryStore` in:

`ios/EpubToMp3/EpubToMp3/Features/Library/Services/LibraryStore.swift`

already had bookmark support:

- `bookmarkData(options: [.withSecurityScope])` on macOS;
- `URL(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:)`;
- stale bookmark refresh;
- `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()` around import and reader I/O.

However, `importBook(from:)` only copied the picked file into durable app storage under `#if os(iOS)`. On macOS it kept `libraryURL = url`, so new rows continued to point at the external Documents/Downloads file. Existing rows also remained external. This meant that security-scoped authorization still mattered for every future external-file access.

## Important entitlements fact

Release entitlements:

`ios/EpubToMp3/EpubToMp3/Resources/EpubToMp3.entitlements`

include:

- `com.apple.security.app-sandbox = true`;
- `com.apple.security.files.user-selected.read-write = true`;
- `com.apple.security.files.bookmarks.app-scope = true`;
- network client entitlement;
- the App Group `group.com.pietrocode.epubtomp3`.

Debug entitlements:

`ios/EpubToMp3/EpubToMp3/Resources/EpubToMp3-Debug.entitlements`

explicitly disable the App Sandbox because local macOS Debug builds are unsigned. This means an unsigned host test cannot prove the exact signed-release TCC behavior. A final live check must use the actual macOS app build/install path and observe the user flow.

Security-scoped bookmarks are the correct mechanism for a user-selected external resource. They are not a license to silently access arbitrary paths. The safer product design here is to copy the selected document into the app-owned container and only retain the external scope for the import/migration operation.

---

## Changes already implemented

### Change 1: Move app-owned macOS audiobook cache to Application Support

Modified:

`ios/EpubToMp3/EpubToMp3/Features/Offline/Services/DownloadManager.swift`

Current behavior:

- macOS: `~/Library/Application Support/EpubToMp3/Audiobooks`
- iOS: existing app-local `Documents/Audiobooks` layout is retained
- `audiobookFolder`, `manifestURL`, `loadManifest`, `localAudioURL`, `saveManifest`, eviction, and storage scanning continue to derive from `audiobooksRoot()`.
- No automatic scan of the old macOS `~/Documents/Audiobooks` path was added, because doing so would reintroduce the permission prompt.

The new macOS constant is:

```swift
nonisolated static let applicationSupportFolderName = "EpubToMp3"
```

The macOS branch uses `.applicationSupportDirectory`; the iOS branch continues using `.documentDirectory` inside the app sandbox.

### Change 2: Copy every imported book into app-owned Application Support

Modified:

`ios/EpubToMp3/EpubToMp3/Features/Library/Services/LibraryStore.swift`

`importBook(from:)` now:

1. Starts access on the fresh picker URL.
2. Hashes and reads the source inside that scope.
3. Copies the original file without deleting it.
4. Stores the copy under:

   `Application Support/EpubToMp3/ImportedBooks/<content-hash>/<original-filename>`

5. Creates/persists the bookmark for the durable app-owned copy.
6. Reads metadata from the durable copy.
7. Stores the resulting `BookEntity` with the durable bookmark.
8. Stops access to the original URL with a balanced `defer`.

The existing helper `persistImportedFileForLibrary(...)` was reused and its default storage was namespaced under `EpubToMp3/ImportedBooks`.

The original selected EPUB/PDF is preserved. Re-importing the same content still de-duplicates by content hash and refreshes the stored durable bookmark/metadata.

### Change 3: Migrate legacy macOS library entries lazily

Modified:

`ios/EpubToMp3/EpubToMp3/Features/Library/Services/LibraryStore.swift`

`openBookFile(id:)` now:

1. Resolves the persisted bookmark with `.withSecurityScope` first on macOS and falls back to plain resolution for unsigned Debug builds.
2. Detects whether the resolved URL is already below `Application Support/EpubToMp3/ImportedBooks`.
3. If it is an old external URL, starts its security-scoped access, copies it into the app-owned directory, creates a new bookmark for the durable copy, and returns the durable URL.
4. Stops access to the old external URL after migration.
5. Refreshes stale bookmarks for already app-owned URLs.
6. Persists the updated `BookEntity`.

This avoids a launch-time scan of external Documents data. Existing library entries are migrated only when the user actually opens them.

Modified model documentation:

`ios/EpubToMp3/EpubToMp3/Features/Library/Models/BookEntity.swift`

The `bookmark` field now documents the durable app-owned copy and the one-time migration behavior for legacy rows.

### Change 4: Regression tests

Created:

`ios/EpubToMp3/EpubToMp3Tests/DownloadManagerStorageTests.swift`

Test:

- `testMacOSAudiobookCacheIsInsideApplicationSupport`
- macOS asserts the cache is below Application Support and not below Documents.
- iOS asserts the app-local Audiobooks layout remains present.

Modified:

`ios/EpubToMp3/EpubToMp3Tests/LibraryStoreTests.swift`

Test:

- `testMacOSImportUsesAnAppOwnedCopyForFutureAccess`
- imports a fixture, opens it through `LibraryStore.openBookFile`, asserts the resolved path is inside `Application Support/EpubToMp3/ImportedBooks`, asserts it is not the source URL, and verifies the copied bytes.

Modified comments only:

`ios/EpubToMp3/EpubToMp3Tests/AudiobookCacheEvictionTests.swift`

The comments were updated so they no longer describe the cache root as `Documents/Audiobooks`.

## TDD evidence

The storage-root test was run RED before the production change and failed with exactly the expected assertions:

- macOS cache was not inside Application Support;
- macOS cache was still inside Documents.

The macOS durable-copy test was then added RED and failed because `openBookFile` resolved back to the external source URL.

During GREEN, one compile error was found and corrected: `LibraryStore` needed its own `applicationSupportFolderName` constant instead of referencing the private constant declared in `DownloadManager`.

The specific durable-copy test then passed.

## Validation already completed after the latest code changes

### Full macOS host test suite

Result bundle:

`/tmp/epub-storage-full2.xcresult`

Summary from `xcrun xcresulttool`:

- Platform: macOS 15.7.7
- Architecture: x86_64
- Total: 858 tests
- Passed: 845
- Skipped: 13
- Failed: 0
- Result: Passed

Command shape used:

```bash
cd /Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3
mise exec -- xcodegen generate
mise exec -- xcodebuild \
  -project EpubToMp3.xcodeproj \
  -scheme EpubToMp3 \
  -destination 'platform=macOS' \
  -derivedDataPath .build-macos-storage-full2 \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -parallel-testing-enabled NO \
  -resultBundlePath /tmp/epub-storage-full2.xcresult \
  test
```

Because this Intel Mac lacks a usable asset-catalog path for the host test setup, the command used a temporary removal of the single `Assets.xcassets in Resources` PBX entry. The command created a backup, installed a shell `trap`, ran the test, and restored the PBX file before exiting. That workaround must never remain in the project.

### Targeted tests

Passed at various points in the final implementation cycle:

- `DownloadManagerStorageTests`
- `LibraryStoreTests/testMacOSImportUsesAnAppOwnedCopyForFutureAccess`
- `LibraryStoreTests`
- `AudiobookCacheEvictionTests`
- `FulltextStoreTests`
- `DownloadManagerBackgroundTests`

### Builds

After the latest `LibraryStore` changes:

- Generic iOS app build: command returned exit 0.
- Share Extension build: the latest parallel command was interrupted with exit 130 when the user sent a new message; it is inconclusive and must be rerun.
- macOS app build: the latest parallel command was not started because the user message arrived; it must be rerun.

Earlier in the architecture migration, generic iOS, Share Extension, and macOS builds all passed, but the final permission-related code still needs the two final build checks above.

### Other verified checks

- `mise exec -- xcodegen generate` completed successfully after adding the new test file.
- `git diff --check` passed.
- No permanent asset-catalog workaround was left in `project.pbxproj`.
- No commit, push, reset, checkout, merge, pull, or history rewrite was performed.

## Remaining work / open risks

### Required before declaring done

1. Rerun the Share Extension generic iOS build after the final `LibraryStore` changes:

```bash
cd /Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3
mise exec -- xcodebuild -quiet \
  -project EpubToMp3.xcodeproj \
  -scheme EpubToMp3ShareExtension \
  -destination 'generic/platform=iOS' \
  -derivedDataPath .build-ios-share-storage-final \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

2. Rerun the macOS app generic build after the final `LibraryStore` changes:

```bash
cd /Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3
mise exec -- xcodebuild -quiet \
  -project EpubToMp3.xcodeproj \
  -scheme EpubToMp3 \
  -destination 'platform=macOS' \
  -derivedDataPath .build-mac-storage-final \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

3. Re-run `git diff --check` and verify that the temporary PBX asset workaround is absent.

4. Inspect the final diff for accidental changes. The repository already has many unrelated architecture changes; do not revert them.

### Live macOS behavior is not yet proven

The host tests prove the path and migration contracts. They do not prove the exact user-facing behavior of a signed, sandboxed, installed macOS app.

A final live check should:

1. Build the real macOS app using the repository's documented `mise` task if available.
2. Use the actual app bundle, not only the XCTest host.
3. Start with a clean test book or a controlled fixture in a user-selected folder.
4. Import the book once through the app's file importer.
5. Quit and relaunch the app.
6. Open the same book without selecting it again.
7. Confirm that the app reads the Application Support copy and does not display the Documents access prompt again.
8. Confirm the original source remains unchanged.
9. Verify a stale/invalid bookmark produces a clear re-import path rather than silently accessing an arbitrary path.

Do not reset the user's TCC permissions or delete real library data during this check without explicit authorization.

### Legacy offline audiobook cache

Old builds stored downloaded audio at:

`~/Documents/Audiobooks`

The new code intentionally does not scan or automatically migrate that folder at launch, because doing so would recreate the permission problem.

This leaves a product decision:

- safest default: leave old cache untouched and let the user re-download offline audio into the new app-owned cache;
- optional future feature: add an explicit user action such as “Import legacy offline cache”, show a clear consent explanation, access the old folder once, copy valid entries into Application Support, verify manifests/files, and never scan that folder automatically on launch.

Do not implement automatic legacy-folder scanning without an explicit UX and permission decision.

### Scope audit still recommended

`Features/Conversion/Views/ConvertView.swift` has a macOS `startAccessingSecurityScopedResource()` call after file selection. Audit that flow for balanced ownership and `stopAccessingSecurityScopedResource()` after the conversion finishes. It is a separate conversion path from `LibraryStore`; do not assume the Library fix covers it.

`Features/Reader/Views/BookOpenView.swift` has multiple reader-side access scopes. Verify each scope is balanced, especially detached parsing tasks and conversion submission paths.

The app must keep the two paths conceptually separate:

- user-selected source file access: scoped and short-lived;
- app-owned imported book/cache access: internal and persistent;
- external legacy cache migration: explicit, opt-in, one-time only.

## Architectural context from the preceding task

The Swift project was reorganized physically by feature without a blanket UIKit/storyboard migration:

- `App/`
- `Features/Conversion/`
- `Features/Documents/`
- `Features/Library/`
- `Features/Offline/`
- `Features/Playback/`
- `Features/Reader/`
- `Features/Settings/`
- `Shared/`

The reader remains UIKit/TextKit/UIPageViewController-oriented in its performance-sensitive path. SwiftUI remains the shell/composition layer.

MVC/MVVM remains selective:

- `ConvertViewModel` and `JobsListViewModel` remain feature-local state coordinators.
- `LibraryStore`, `AudioPlayer`, `ReaderCoordinator`, download managers, and cache managers remain domain services/state owners.
- Do not create ViewModels merely because a file is a SwiftUI View.

The architecture plan is:

`docs/plans/ios-feature-architecture.md`

This new macOS permission plan is a follow-up to that completed physical organization.

## Recommended execution order for the next agent

1. Read this file and inspect the current diff.
2. Rerun the final Share Extension build.
3. Rerun the final macOS app build.
4. Run `git diff --check` and inspect status/diff.
5. Audit the conversion and reader security-scope call sites.
6. If those call sites are changed, add focused tests first and rerun the full macOS host suite plus relevant builds.
7. Perform the signed macOS live import/relaunch verification if the build/install task is available and the user authorizes it.
8. Report clearly what was verified, what is inferred, and what remains unknown.

Do not claim “one prompt verified” from unit tests alone. The durable path is implemented and host-tested; installed signed-app behavior remains the final acceptance check.
