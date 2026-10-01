# Desktop, Mobile, and Releases

## Apple (macOS / iPadOS / iOS) — UIKit/AppKit

<<<<<<< HEAD
The official Apple client lives in `ios/EpubToMp3/`. macOS embeds the Rust
`converter-server` inside the `.app`; iPadOS and iOS talk to a remote backend.
||||||| e1d1565d6e
The official Apple client lives in `ios/EpubToMp3/`. macOS embeds the
Python server as a PyInstaller sidecar inside the `.app`; iPadOS and iOS
talk to a remote backend.
=======
The official Apple client lives in `ios/EpubToMp3/`. macOS embeds the
Python runtime inside the `.app`; iPadOS and iOS
talk to a remote backend.
>>>>>>> origin/chore/repository-trust

Headless macOS build:

```bash
mise run mac:build
# → task prints the produced .app path, usually ios/EpubToMp3/.build/Release/EpubToMp3.app
```

<<<<<<< HEAD
Sidecar-only build (Rust release binary):

```bash
mise run sidecar:build
# → dist/epub-to-mp3-server
```
||||||| e1d1565d6e
Sidecar-only build (PyInstaller onefile):

```bash
mise run sidecar:build
# → dist/epub-to-mp3-server
```
=======
>>>>>>> origin/chore/repository-trust

Open in Xcode:

```bash
cd ios/EpubToMp3
xcodegen generate
open EpubToMp3.xcodeproj
```

## Non-Apple (Linux / Windows / Android) — Flutter

The official non-Apple client lives in `flutter_app/`. Single Dart codebase,
same FastAPI contract.

```bash
mise run flutter:build-linux        # Linux desktop release
mise run flutter:build-windows      # Windows desktop release
mise run flutter:build-apk          # Android (release)
```

## Releases

`release-desktop.yml` runs on every `v*.*.*` tag and publishes:

- macOS `.zip` (native Apple app with embedded Python runtime)
- Linux `.tar.gz` (Flutter)
- Windows `.zip` (Flutter)
- Android `.apk` (Flutter)
- Docker image (`ghcr.io/<owner>/epub-to-mp3:latest`)
- iOS unsigned archive (sideload via AltStore)
