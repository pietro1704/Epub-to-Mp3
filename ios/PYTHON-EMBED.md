# In-Process Python on iOS — Spike

Branch: `feat/ios-python-embed`. Status: **proof-of-concept, simulator-only**.

## Why

The macOS app embeds a PyInstaller-built FastAPI sidecar and launches it with
`Process()`. iOS does not allow `Process()` or any child-process spawning;
every line of the conversion pipeline therefore has to run **in-process**
inside the SwiftUI app. This spike proves the path is real before we sink
weeks into porting `server.py` to a `BackgroundTasks`-driven in-process
runtime.

## Architecture

```
+----------------------------------------------------+
| EpubToMp3.app  (iOS / iOS Simulator)              |
|                                                    |
|   SwiftUI views                                    |
|        |                                           |
|        v                                           |
|   PythonEmbed.swift  ----PythonKit---->            |
|        |                                           |
|        |  dlopen / @rpath                          |
|        v                                           |
|   Python.xcframework  (Beeware build, libpython3.13)
|        + python-stdlib/        (in .app/Resources) |
|        + site-packages/        (in .app/Resources) |
|             |                                      |
|             +-- edge_tts (pure Python)             |
|             +-- aiohttp + transitive C exts        |
+----------------------------------------------------+
```

macOS keeps using the sidecar binary (`SidecarManager.swift`,
`epub-to-mp3-server`); all new code is wrapped in
`#if os(iOS) || targetEnvironment(simulator)`.

## Bootstrap

```bash
ios/EpubToMp3/scripts/bootstrap-ios-python.sh
cd ios/EpubToMp3
mise exec -- xcodegen          # regenerate xcodeproj with PythonKit + xcframework
```

The script:
- Downloads `Python-3.13-iOS-support.b13.tar.gz` from
  [beeware/Python-Apple-support](https://github.com/beeware/Python-Apple-support).
- Caches the tarball at `~/.cache/epub-to-mp3/python-apple-support/`.
- Extracts `Python.xcframework` + `python-stdlib/` into
  `ios/EpubToMp3/EpubToMp3/Vendor/Python/` (gitignored, ~150 MB).
- `pip install --target ios/EpubToMp3/EpubToMp3/Vendor/site-packages` for
  `edge-tts` + `aiohttp`.

Override the Python version via env:

```bash
PY_VERSION=3.13 PY_BUILD=b13 ./scripts/bootstrap-ios-python.sh
```

## Running the smoke test

Open the `EpubToMp3.xcodeproj` and run the `EpubToMp3Tests` scheme against
any iOS Simulator. The relevant test is `PythonEmbedTests`:

- `testBootstrapIsIdempotent` — sanity check that `Py_Initialize` only
  fires once.
- `testEdgeTTSConvertsHelloWorld` — synthesizes a short pt-BR utterance
  via Edge-TTS in-process and asserts the resulting MP3 is > 5 KB.

CLI (Apple Silicon host):

```bash
xcodebuild test \
  -project ios/EpubToMp3/EpubToMp3.xcodeproj \
  -scheme EpubToMp3 \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:EpubToMp3Tests/PythonEmbedTests
```

The test `XCTSkip`s itself if the bootstrap hasn't been run.

## Known limits (spike scope)

| Limit | Why | Unblock |
|---|---|---|
| **Simulator only** | `aiohttp` C extensions installed via pip ship macOS arm64 wheels. Those load in the iOS simulator (same Mach-O slice) but **not** on real device. | Cross-compile `aiohttp` + transitive C deps with `kivy-ios` or `cibuildwheel --platform ios` (3.13 supports this since CPython PEP 730). |
| **pt-BR only** | Test only exercises one voice. | Edge supports every locale already; no further work. |
| **Edge-TTS only** | Piper is the offline fallback in production. ONNX Runtime ships an iOS pod but is not wired here. | Add `onnxruntime` iOS pod, embed Piper ONNX models, port `tts/piper_engine.py` minimal surface. |
| **One-shot synth** | `Communicate.save()` blocks until the whole MP3 is on disk. No SSE / streaming chapters. | Wire `Communicate.stream()` async generator into an `AsyncStream<Data>` to match the existing `AudioPlayer.updateSnapshot` contract. |
| **No `server.py`** | The HTTP server isn't running inside the app. | Two paths: (a) stand up `Hypercorn`-in-process listening on `127.0.0.1`, or (b) write a Swift shim that translates `APIClient` calls directly into Python function calls — skips HTTP entirely. |

## Next steps (post-spike, if approved)

1. Confirm real-device build via cibuildwheel cross-compile of `aiohttp`,
   `multidict`, `yarl`, `frozenlist`, `propcache`, `charset-normalizer`.
2. Embed Piper via `onnxruntime` iOS pod; ship pt-BR + en-US models.
3. Decide on the in-process server vs direct-bridge architecture for
   `APIClient` to keep the rest of SwiftUI agnostic.
4. App size budget: Python.xcframework (~80 MB) + stdlib (~30 MB) + slim
   site-packages (~10 MB) ≈ 120 MB before App Thinning. Audit
   `python-stdlib/` and drop unused submodules (`tkinter`, `test/`,
   `idlelib/`, `turtledemo/`, ensurepip).
