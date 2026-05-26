# EpubToMp3 — Apple native app (SwiftUI)

The official Apple client for the project. Single SwiftUI codebase
that ships to **macOS, iPadOS and iOS** out of the same Xcode project.
On macOS the app embeds the Python backend (PyInstaller sidecar) so it
runs offline; on iOS / iPadOS it talks to a remote backend (`mise run
web` locally, or HF Spaces).

## Mental model

The app is **a reader first, a converter second**:

1. The **Library** is the home screen — every EPUB the user has
   imported, identified by SHA-256 of file content (survives renames).
2. **Tap a book** → opens `BookOpenView`. If the book already has a
   conversion job, the existing audio is reattached. Otherwise the
   sidecar starts a fresh conversion and `PlayerReaderView` mounts
   immediately — the reader pane shows the EPUB text from
   `/api/jobs/{id}/fulltext`, while the player streams chapters as
   their `downloadUrl` becomes available via SSE.
3. Conversion knobs (engine, voice, telemetry, raw logs) live under
   **Settings → Advanced** — reachable but not the front door.

## Building

Open in Xcode 26 (project is generated via XcodeGen):

```bash
cd ios/EpubToMp3
xcodegen generate
open EpubToMp3.xcodeproj
```

Pick **My Mac** for native macOS, **iPhone/iPad simulator** for iOS.
For the macOS sidecar to be embedded, build the PyInstaller binary
first:

```bash
mise run sidecar:build      # writes dist/epub-to-mp3-server
```

Or do both steps in one shot:

```bash
mise run mac:build          # sidecar:build + headless xcodebuild
```

The Xcode `postBuildScripts` phase copies the most recent binary into
the `.app`'s Resources folder. Without it the macOS app falls back to
the user-configured backend URL (Settings → Backend).

## Streaming playback

`AudioPlayer.updateSnapshot(_:)` is the entry point: it merges a fresh
`JobSnapshot` into the running `AVQueuePlayer` queue without
interrupting the chapter currently playing. `PlayerReaderView`
subscribes to `/api/jobs/{id}/stream` (SSE) and drives the merge,
which is what gives the user "tap → start listening" while the rest
of the book is still being synthesised.

## Library persistence

`LibraryStore` keeps a JSON list of `BookEntity` records under
`UserDefaults` key `library.books.v1`. Each entry holds:

- `id` — SHA-256 of file content (32 hex chars)
- `bookmark` — security-scoped bookmark to the EPUB on disk
- `title`, `author`, `coverPNG` — best-effort from EPUB metadata
- `lastJobId` — last conversion run (so taps reattach to existing audio)
- `cachedOffline` — whether the user opted in to keeping the full MP3

EPUB metadata is parsed by `EpubMetadataReader`. On macOS we shell out
to `/usr/bin/unzip -p`; on iOS we currently fall back to filename
heuristics (a Swift-only zip reader is the obvious next iteration).

---

## Legacy slice notes (kept for archeology)

The sections below describe the slice-2 / slice-3 work that the
current redesign builds on. Field semantics still apply — the Library
hero is a layer on top of the same backend contract.

**Slice 2** added: `JobSnapshot` Codable model mirroring the
`JobStatus` Pydantic schema, `AVQueuePlayer`-backed audio engine with
lock-screen / `MPRemoteCommandCenter` integration, background-aware
`DownloadManager`, modal `PlayerView` with scrubber + speed selector,
and per-`(jobId, chapterIndex)` resume markers persisted in
`UserDefaults`.

**Slice 3** (current) adds the side-by-side EPUB reader synchronised
with audio playback:

- `EbookFulltext` — Codable mirror of `GET /api/jobs/{id}/fulltext`.
  The wire format is `chapters[].{index, name, text, html, css, charCount}`
  (1-based `index`, no stable string id, no `segments[]` field today
  — the model accepts an optional `segments[]` for forward compat).
- `FulltextStore` — disk cache at
  `<documents>/Audiobooks/<jobId>/fulltext.json`, retry ladder
  `[800, 1500, 3000, 6000, 12000] ms` for 503 responses, hard-fail on
  404/422 per memory `project_reader_fulltext.md`. Exposes
  `watch(jobId:) -> AsyncStream<EbookFulltext>`.
- `SyncEngine` — pure-logic mapper from `AudioPlayer.position` to a
  current sentence id. Walks a `(sentenceId, startMs, endMs)` table
  built from segment metadata when available, otherwise from a
  WPM-based estimation (default 200 WPM, configurable per
  instance). Re-emits only on sentence change. No AVFoundation, no
  SwiftUI — runs headless in the SPM target.
- `ReaderView` — `ScrollViewReader` + `LazyVStack` of sentence rows;
  the active sentence gets `.background(.yellow.opacity(0.35))` and
  the scroll view animates it to the centre. Toolbar exposes font
  size (5 steps), font family (serif / sans / mono), theme (light /
  sepia / dark / black), and an auto-scroll toggle. Manual drags
  pause auto-scroll for 1.5s so user navigation isn't fought by the
  animation.
- `TocDrawer` — slide-over chapter list driven by the fulltext
  payload (or `playableChapters` as fallback). Tap to jump audio +
  reader simultaneously.
- `PlayerReaderView` — replaces the slice-2 `PlayerView` sheet with
  a `fullScreenCover` split: phone gets reader-on-top / transport-
  on-bottom; iPad regular size class flips to side-by-side.
- `AppSettings` extended with `readerFontSize`, `readerFontFamily`,
  `readerTheme`, `readerAutoScroll` via `@AppStorage`.

### Endpoint contract recap (slice 3)

| Status | Meaning                                          | iOS handling                          |
|--------|--------------------------------------------------|---------------------------------------|
| 200    | Chapters available                               | Decode + persist + emit                |
| 404    | Job gone or terminal-failed with no source       | `FulltextError.gone`, no retry        |
| 422    | Parsed cleanly, zero chapters                    | `FulltextError.emptyParse`, no retry  |
| 503    | Source not yet on disk / parsing in progress     | Retry ladder `[800,1500,3000,6000,12000]`ms then `transientExhausted` |

**Contract diff vs slice-3 brief:** the brief assumed
`chapters[].{id, title, text, segments?}`. The actual server wire
format uses `index` (1-based int) + `name`. We synthesise `id` as
`String(index)` and treat `name` as the title.  No `segments[]`
field exists in the server payload today — `SyncEngine` always
falls back to WPM estimation. The Codable model accepts
`segments[]` so a future backend can drop it in without an iOS
change.

## Layout

```
ios/EpubToMp3/
├── Package.swift                 # SPM target for headless `swift build` of Models + Services
├── EpubToMp3/
│   ├── EpubToMp3App.swift        # @main entry — sets up AppSettings + RootView
│   ├── Models/
│   │   ├── AppSettings.swift     # @Observable, @AppStorage backendURL
│   │   ├── SessionRecord.swift   # Codable mirror of /api/sessions records
│   │   └── JobSnapshot.swift     # Codable mirror of /api/jobs/{id} (camelCase!)
│   ├── Services/
│   │   ├── APIClient.swift       # fetchSessions, fetchJob, SSE eventStream
│   │   ├── AudioPlayer.swift     # AVQueuePlayer + MPNowPlayingInfoCenter
│   │   ├── DownloadManager.swift # background URLSession + manifest.json
│   │   └── ResumeStore.swift     # UserDefaults-backed (jobId,chapter) → seconds
│   └── Views/
│       ├── RootView.swift        # TabView (Jobs | Settings)
│       ├── SettingsView.swift    # backend URL + bundle metadata
│       ├── JobsListView.swift    # /api/sessions list, pull-to-refresh
│       ├── JobDetailView.swift   # snapshot + SSE + chapter list + Play/Download
│       └── PlayerView.swift      # modal player (scrubber, speed, transport)
└── EpubToMp3Tests/                # XCTest — JobSnapshot decoding, ResumeStore, DownloadManager helpers
```

### Backend contract correction

The slice-2 task brief assumed snake_case (`book_title`, `progress`,
`mp3_url`, …) for `/api/jobs/{id}`. **The wire format is actually
camelCase** — the FastAPI `JobStatus` BaseModel in `python_app/server.py`
uses `jobId`, `bookTitle`, `chapterProgress`, `progressPercent`,
`chaptersTotal`, etc. and `_job_status_payload` returns the dict
verbatim. `JobSnapshot.swift` matches that. Notable shape differences
from the brief:

- Per-chapter MP3s are exposed as `chapterProgress[].downloadUrl`
  (not `chapters[].mp3Url`).
- Chapter byte size is not exposed per chapter; only top-level
  `outputs[].sizeBytes` (ZIP / log).
- `durationSeconds`, `startedAt`, `completedAt` are *optional* per
  chapter — the running path doesn't populate them; the recovery path
  doesn't either, so consider them best-effort hints.

### Audio session + Info.plist requirements

`EpubToMp3App.configureAudioSession()` runs once on `init()`:

```swift
try AVAudioSession.sharedInstance().setCategory(
    .playback, mode: .spokenAudio,
    options: [.allowBluetoothA2DP, .allowAirPlay]
)
try AVAudioSession.sharedInstance().setActive(true)
```

Add to `Info.plist` so iOS keeps the app alive while playing:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

For the Files-app integration (so users can hand the resulting MP3s
off to their preferred audio app):

```xml
<key>UIFileSharingEnabled</key><true/>
<key>LSSupportsOpeningDocumentsInPlace</key><true/>
```

The `DownloadManager` writes to
`<documents>/Audiobooks/<jobId>/chapters/*.mp3` plus
`<documents>/Audiobooks/<jobId>/manifest.json`. With the keys above,
those files become visible in the Files app under "On My iPhone →
EpubToMp3".

### What works in slice 2

- `JobSnapshot` decoding from both `GET /api/jobs/{id}` and SSE frames.
- `AudioPlayer.play(snapshot:startingAt:)` builds the chapter playlist
  and starts playback. `pause`/`resume`/`seek`/`next`/`previous` work.
- Lock-screen / control-center transport via `MPRemoteCommandCenter`.
- Now Playing metadata (book title, chapter title, position, rate).
- Speed selector at `0.75x–2.0x`.
- Resume position persists per `(jobId, chapterIndex)` and is restored
  on next `play()`.
- `DownloadManager` enqueues every MP3 from the snapshot, retries with
  exponential backoff (1s/2s/4s/8s/16s/30s ceiling, max 6 attempts),
  writes a `manifest.json` per audiobook.

### Stubbed / deferred to slice 3

- Real `URLSession.background` delegate-driven downloads (slice 2 uses
  the foreground session under a `Task.detached` queue — works but
  pauses when the app is suspended).
- SHA256 verification (`?sha=true` not yet exposed by backend).
- Sleep timer + skip-silence.
- Cache eviction (LRU) when `~/Documents/Audiobooks` exceeds the user
  budget.
- Wi-Fi-only toggle (`NWPathMonitor` gating on `enqueueAll`).
- Artwork download via `coverUrl` (currently a `headphones` SF Symbol
  placeholder).
- Conversion submission (POST /api/convert + file picker) — slice 4.

### Headless validation status

```
$ swift build      # compiles Models + Services + AudioPlayer (macOS 14)
Build complete!
$ swift test       # 12/12 pass — JobSnapshotTests + ResumeStoreTests + DownloadManagerHelperTests
```

`PlayerView.swift`, `JobDetailView.swift`, and `EpubToMp3App.swift`
import SwiftUI and need an iOS SDK / Xcode build to compile. They are
intentionally excluded from the SPM target.

## Approach: no hand-written `.xcodeproj`

Hand-rolling `project.pbxproj` is brittle and Xcode regenerates it cleanly on
first open. So instead:

1. **`Package.swift`** in `ios/EpubToMp3/` validates the headless code
   (Models/SessionRecord.swift + Services/APIClient.swift) with
   `swift build` from any macOS shell — no Xcode required, no iOS SDK
   required. Useful for CI smoke checks on the JSON contract.
2. **Xcode generates the iOS project** when you open the folder. See "Open
   in Xcode" below.

## Open in Xcode

1. Open Xcode 16 (iOS 17+ SDK) and choose
   **File → New → Project… → iOS → App**.
2. Settings:
   - Product Name: `EpubToMp3`
   - Bundle Identifier: `com.pietrocode.epubtomp3`
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Storage: **None**
   - Deployment Target: **iOS 15.0**
3. Save the new project on top of `ios/EpubToMp3/`. When Xcode asks about
   overwriting `EpubToMp3App.swift`, **cancel and replace it instead** by
   deleting Xcode's generated `EpubToMp3App.swift` and dragging the existing
   `EpubToMp3/` folder (with **"Create groups"**, target = `EpubToMp3`) into
   the project navigator.
4. In Build Settings:
   - `IPHONEOS_DEPLOYMENT_TARGET` → `15.0`
   - `PRODUCT_BUNDLE_IDENTIFIER` → `com.pietrocode.epubtomp3`
5. App Transport Security: to hit `http://localhost:8000` from the simulator,
   add to Info.plist:
   ```xml
   <key>NSAppTransportSecurity</key>
   <dict>
     <key>NSAllowsLocalNetworking</key><true/>
   </dict>
   ```
6. Build & run on the smallest available compatible iPhone simulator. First launch shows
   the empty Jobs list — switch to **Settings**, leave the URL as
   `http://localhost:8000` for the local backend, then pull-to-refresh
   on **Jobs**.

## Headless validation

```bash
cd ios/EpubToMp3
swift build      # compiles Models + Services against macOS SDK; no Xcode needed
```

Last verified: `Build complete!` on the macOS host.

## What works in this slice

- Settings tab persists `backendURL` via `@AppStorage` (UserDefaults).
- Jobs tab calls `GET /api/sessions?last=100`, decodes records using
  `CodingKeys` matching the Python session log (`book_title`,
  `chapters_converted`, `duration_seconds`, …), renders a `List` with
  outcome badge, engine, chapter count, and timestamp.
- Tapping a session pushes a Job Detail view that opens
  `GET /api/jobs/{id}/stream` over `URLSession.bytes(for:)` and exposes the
  SSE frames as an `AsyncThrowingStream<JobEvent>`. The latest event payload
  and a running counter are displayed live.

## Stubbed / not yet implemented

- **Audio playback** — no `AVAudioPlayer` integration. The list of MP3
  outputs from `JobSnapshot.outputs` is not decoded yet.
- **Conversion submission** — no `POST /api/convert` form (no file picker,
  no engine/voice selection).
- **Job snapshot decoding** — SSE payloads are surfaced as raw JSON strings
  for debugging only; full `JobSnapshot` model will arrive in slice 2.
- **The `bookTitle`-as-jobId hack** in `JobsListView` is a placeholder; the
  session log does not yet expose a stable job id, so the live SSE view
  will be wired through the upcoming `/api/jobs/recent` endpoint that
  *does* return ids.
- **Offline cache, share extension, background downloads** — slice ≥ 3.

## Backend endpoints currently consumed

| Method | Path                          | Purpose                          |
|--------|-------------------------------|----------------------------------|
| GET    | `/api/sessions?last=N`        | History list (read-only)         |
| GET    | `/api/jobs/{id}/stream`       | SSE live updates for a running job |

Defined in `python_app/src/routes_sessions.py` and `python_app/server.py`.
