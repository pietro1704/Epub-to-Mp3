# Native iOS parity acceptance

Reference: `bca454ffcbd32cec7f3eebb193f9a30f85c8930c` (2026-11-10).
Sources are under `ios/EpubToMp3/EpubToMp3/`. This specification is a
reference contract, not a claim that device acceptance has passed.

## Device presentations

Compact widths use bottom navigation with Library, Settings, Convert. Opening a
book presents the reader directly. Expanded widths use a sidebar and constrained
reading columns, dialogs and player panels. Rotation recomputes geometry while
retaining the same source anchor. A tablet is not a stretched phone screen.

| Journey | Native reference | Required observable result |
| --- | --- | --- |
| Shell | App/IOSAppShell.swift, App/IOSRootContainer.swift | Three destinations; independent active reader; coherent chrome/player visibility |
| Library | Features/Library/Views/LibraryScreenController.swift | Search, sort, covers, direct open, explicit whole-book conversion |
| Reader | Features/Reader/Views/ReaderViewComposition.swift | EPUB/PDF, contents, search, annotations and complete visible lines |
| Viewport | Features/Reader/Services/ReaderViewportTransition.swift | Chrome round trip preserves raw offset; explicit turns use page boundaries |
| Typography | Features/Reader/Views/ReaderSettingsPresentation.swift | Original document styling unless explicitly overridden; no lost source anchor |
| Listening | Features/Playback/Services/PlaybackChapterSession.swift | First Play prepares audio; opening alone neither synthesizes nor plays |
| Alignment | Features/Playback/Services/PlaybackSpeechAlignment.swift | Measured word timing only; no stale book/chapter/item highlight |
| Player | Features/Playback/Views/FullPlayerContent.swift | Consistent compact/expanded controls, seek intervals, queue, sleep and rate |
| Conversion | Features/Conversion/Views/ConvertScreenController.swift | Local Rust jobs, progress, cancellation, retry and playable export |
| Settings | Features/Settings/Views/SettingsScreenController.swift | Explicit model installation, actual voice feedback and protected offline audio |

## Fixture and lifecycle matrix

Use `test/fixtures/parity/chapter.xhtml` for structured text, links, repeated
phrases and Unicode. Use an actual EPUB containing the same kinds of resources,
the established Lord of the Rings fixture when available, and a known PDF for
physical acceptance. Verify source hierarchy, images, notes and link targets.

Run phone AND tablet journeys in portrait/landscape, light/dark, default/large
text and visible/hidden chrome. Verify first/final page, rapid repeated chrome
toggles, settings changes, interrupted conversion, book switch, unavailable
voice, app restart, offline playback and Android media controls. Preserve
production books, models, downloads, bookmarks and preferences.

## Evidence and delivery

Each of the six plan points has a separate PR and local review after each code
change. Automated checks run during implementation. Per the user's instruction,
opening the app and physical-device verification happen only after all six
points are integrated in the final candidate. Keep PRs draft until that runtime
acceptance is complete. Record source/APK/runtime identity, device model/API,
commands/results and screenshots for BOTH devices. Native screenshots must have
known source/build identity before being used as visual proof.

Current device discovery: USB SM-A530F (Galaxy A8), Android 9. Tablet wireless ADB
was advertised but not authorized/connected. Confirm its model before selecting
the expanded acceptance target. Neither device has passed candidate acceptance.
