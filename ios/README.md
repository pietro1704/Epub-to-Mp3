# EpubToMp3 iOS Companion (vertical slice)

Minimal SwiftUI scaffold that talks to the Python backend (FastAPI) running
either locally (`mise run web`, default `http://localhost:8000`) or on a
remote tunnel / HF Spaces deploy.

This is **slice 1**: skeleton + API connection only. No upload, no audio
playback, no offline cache yet.

## Layout

```
ios/EpubToMp3/
├── Package.swift                 # SPM target for headless `swift build` of Models + Services
├── EpubToMp3/
│   ├── EpubToMp3App.swift        # @main entry — sets up AppSettings + RootView
│   ├── Models/
│   │   ├── AppSettings.swift     # @Observable, @AppStorage backendURL
│   │   └── SessionRecord.swift   # Codable mirror of /api/sessions records
│   ├── Services/
│   │   └── APIClient.swift       # async/await fetchSessions + SSE eventStream
│   └── Views/
│       ├── RootView.swift        # TabView (Jobs | Settings)
│       ├── SettingsView.swift    # backend URL + bundle metadata
│       ├── JobsListView.swift    # /api/sessions list, pull-to-refresh
│       └── JobDetailView.swift   # SSE stream consumer (URLSession.bytes)
```

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
   - Deployment Target: **iOS 17.0**
3. Save the new project on top of `ios/EpubToMp3/`. When Xcode asks about
   overwriting `EpubToMp3App.swift`, **cancel and replace it instead** by
   deleting Xcode's generated `EpubToMp3App.swift` and dragging the existing
   `EpubToMp3/` folder (with **"Create groups"**, target = `EpubToMp3`) into
   the project navigator.
4. In Build Settings:
   - `IPHONEOS_DEPLOYMENT_TARGET` → `17.0`
   - `PRODUCT_BUNDLE_IDENTIFIER` → `com.pietrocode.epubtomp3`
5. App Transport Security: to hit `http://localhost:8000` from the simulator,
   add to Info.plist:
   ```xml
   <key>NSAppTransportSecurity</key>
   <dict>
     <key>NSAllowsLocalNetworking</key><true/>
   </dict>
   ```
6. Build & run on an iOS 17 simulator. First launch shows the empty Jobs
   list — switch to **Settings**, leave the URL as `http://localhost:8000`
   (or point to a tunnel), then pull-to-refresh on **Jobs**.

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
