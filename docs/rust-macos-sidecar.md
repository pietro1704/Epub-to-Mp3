# Rust macOS sidecar

The native macOS app bundles `converter-server` as
`Contents/Resources/epub-to-mp3-server`. macOS no longer packages or launches
the Python/PyInstaller desktop entry point. iOS keeps its in-process Python
runtime because it cannot launch a native server process.

## Build

```bash
mise run sidecar:build
mise run mac:build
```

The sidecar task compiles the release `converter-server` workspace member and
copies it to `dist/epub-to-mp3-server`. The Xcode post-build phase embeds that
executable in the app Resources directory and fails if it is missing.

## Runtime contract

- `PORT` selects the HTTP port; the desktop default remains `47860`.
- `HOST` defaults to `0.0.0.0`, matching the existing server contract.
- `/health` returns HTTP 200 with `{"status":"ok"}` for readiness polling.
- stdout/stderr stay attached to the native process for app log capture.
- terminating the child shuts down the server; no PyInstaller worker or
  temporary extraction directory is involved.

The sidecar receives the same path and conversion environment variables as the
desktop app, including `PERSISTENT_ROOT`, `CACHE_DIR`, and `OUTPUT_DIR`.