# In-Process Python on iOS

Status: the app uses an in-process Python conversion boundary and a native
Swift Edge transport. The macOS live streaming test and signed iPhone arm64
bundle installation pass; real-device playback remains required before a
release, and the current adapter is not yet full CLI-policy parity. See
[`docs/ios-in-process-edge-audio-architecture-research-2026-07-30.md`](../docs/ios-in-process-edge-audio-architecture-research-2026-07-30.md)
for the current Apple-platform design and acceptance evidence.

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
|   UIKit views                                      |
|        |                                           |
|        +----> EdgeTTSBridge.swift   (network I/O) |
|        |          URLSession + URLSessionWebSocketTask
|        |          wss://speech.platform.bing.com/...
|        |                                           |
|        v                                           |
|   PythonEmbed.swift  ----PythonKit---->            |
|        |                                           |
|        |  dlopen / @rpath                          |
|        v                                           |
|   Python.xcframework  (Beeware build, libpython3.13)
|        + python-stdlib/        (target-matched binary modules) |
|        + site-packages/        (empty placeholder) |
+----------------------------------------------------+
```

Swift owns **all** networking. Python stays in-process for the
**canonical pipeline modules** — `python_app.src.ebook_reader`,
`text_formatting`, `cache_manager`, `paths` — which are pure-stdlib and
shared with the macOS sidecar and the HF Spaces backend. The iOS app
imports them via `PythonBridge.swift` so there is exactly one EPUB
parser in the codebase, not a Swift reimplementation racing the
Python one. Swift owns networking; synthesis bytes come from
`EdgeTTSBridge`. CPython binary modules used by EPUB parsing are copied
from the exact device, simulator, or macOS `Python.xcframework` slice
during the Xcode build.

This is the production-targeted shape — `aiohttp` and the rest of the
TCP/TLS chain are gone, so Edge network I/O remains entirely inside the
public URLSession API. The bundled CPython support package supplies the
standard library's target-specific dynamically loaded modules, including
the modules required to read compressed EPUB containers.

macOS keeps using the sidecar binary (`SidecarManager.swift`,
`epub-to-mp3-server`); all new code is wrapped in
`#if os(iOS) || targetEnvironment(simulator)`.

## Bootstrap

### Auto-bootstrap (default)

The bootstrap is wired into the build pipeline at two layers so you never
have to invoke the shell script directly:

1. **Mise task dependency** — `mise run ios:build` and `mise run mac:build`
   list `vendor:python` in their `depends`, so the xcframework is materialized
   before `xcodebuild` runs. The task uses mise's `sources`/`outputs`
   incremental cache, so it's a near-instant no-op once the framework is on
   disk.
2. **Xcode build-script phases** — the EpubToMp3 target runs
   "Bootstrap Python.xcframework" before compilation and syncs the canonical
   `python_app` source tree. A post-build phase then runs
   `sync-embedded-python-runtime.sh` against the built app bundle, selecting
   `lib-dynload` from the matching device, simulator, or macOS XCFramework
   slice. This keeps simultaneous macOS and iPhone builds from overwriting
   each other's binary Python modules.

Manual override (force a re-bootstrap or run on a fresh clone before opening
Xcode):

```bash
mise run vendor:python
```

### What it does

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
  `ios/EpubToMp3/Vendor/` (gitignored, ~150 MB).
- During each Xcode build, copies `lib-dynload` from the matching
  `Python.xcframework` slice. An iPhone build therefore receives arm64
  `*-iphoneos.so` modules, while the simulator and macOS receive their own
  binaries.
- Copies `python_app/src/` into
  `ios/EpubToMp3/EpubToMp3/Vendor/site-packages/python_app/` so the
  Swift bridge can `Python.import("python_app.src.ebook_reader")` and
  call the same parser the macOS sidecar / HF backend run.
- Does NOT install `aiohttp` / `edge-tts` — the Swift `EdgeTTSBridge`
  owns synthesis; `site-packages/` otherwise carries only the embedded
  `python_app` tree.

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
  -destination 'platform=iOS Simulator,name=iPhone SE,OS=17.2' \
  -only-testing:EpubToMp3Tests/PythonEmbedTests
```

The test `XCTSkip`s itself if the bootstrap hasn't been run.

## Known limits (spike scope)

| Limit | Why | Unblock |
|---|---|---|
| **Physical-device runtime validation pending** | The iPhone arm64 build selects CPython binary modules from the exact XCFramework slice and installs successfully. The equivalent macOS live test completes the PythonKit → Swift Edge WSS stream, but the connected device is locked before the iPhone can prove playback. | Unlock the connected iPhone, then run the local Edge streaming XCTest and manual Listen flow. |
| **pt-BR only** | Test only exercises one voice. | Edge supports every locale already; no further work. |
| **Edge-TTS only** | Piper is the offline fallback in production. ONNX Runtime ships an iOS pod but is not wired here. | Add `onnxruntime` iOS pod, embed Piper ONNX models, port `tts/piper_engine.py` minimal surface. |
| **CLI policy parity** | The streaming adapter invokes `ios_entrypoints.synthesize_chapter_streaming`, not `AudioConverter`; retry, fallback, validation, telemetry, and adaptive concurrency policies are not all shared yet. | Extract the portable conversion policy behind an injected chunk transport and compare deterministic CLI/iOS contract fixtures. |
| **No `server.py`** | The HTTP server isn't running inside the app. | Keep the direct PythonKit bridge; a loopback HTTP server adds lifecycle and background failure modes without improving the local contract. |

## Runtime validation gap

The transport seam (`python_app/src/tts/_edge_transport.py`) and the iOS
entrypoint (`python_app/src/ios_entrypoints.py`) have Python-side regression
coverage for transport swapping, chunking, byte concatenation, no-audio
errors, and environment clamping. A macOS live XCTest now proves the embedded
PythonKit → Swift WebSocket round trip with ordered streamed MP3 segments and
the final MP3 file. It is not evidence that an actual iPhone can complete
playback through `AVQueuePlayer`.

The Swift side -- `PythonEmbed.installEdgeTransport()` registering an
`EdgeTTSBridge`-backed `PythonFunction` via PythonKit, and
`PythonBridge.convertChapter` routing through
`ios_entrypoints.synthesize_chapter_via_transport` -- is covered by the
macOS live stream test, but still requires a real iPhone playback smoke. A
successful iPhone compilation alone would not be conclusive because:

* `PythonKit`'s `PythonFunction` initializer signature and the
  `Python.bytes(...)` / `Python.list(...)` bridges behave subtly
  differently between SDKs; the exact call shape used in
  `installEdgeTransport` needs an iOS-runtime smoke before we trust
  it.
* The `DispatchSemaphore` bridge from `async` Swift back to a sync
  Python callable can deadlock if the calling thread already owns
  the semaphore -- needs a real run to verify the
  `Task.detached(priority: .userInitiated)` escape hatch is enough.
* The synchronous Python transport callback must release immediately when a
  Listen request is replaced. The bridge now cancels the active WebSocket and
  resolves its one-shot gate, but a physical-device smoke still has to prove
  the complete cancellation/restart path under real network timing.

Followups before declaring this slice release-ready:

1. On a physical iPhone, import an EPUB, start local Edge conversion, and
   verify the first local MP3 segment plays while later segments convert.
2. Verify the same session across Lock Screen controls, an interruption,
   and a headphone-disconnect route change.
3. Run a deterministic CLI/iOS conversion-contract fixture that compares
   prepared text, ordered bytes, cache decisions, retry outcome, and errors.
4. Measure latency overhead of the Swift-to-Python-to-Swift hop per chunk
   versus direct `EdgeTTSBridge.synthesize`.

## Next steps

1. Extract shared conversion policy with an injected Edge chunk transport;
   do not introduce a loopback server just to call Python in the same process.
2. Embed Piper via `onnxruntime` iOS pod if offline parity becomes a product
   requirement; ship the required language models with the app.
3. Keep local conversion checkpoints in app-managed storage and resume only
   when foreground execution is available; background audio must not promise
   indefinite WebSocket conversion.
4. App size budget: Python.xcframework (~80 MB) + stdlib (~30 MB) + slim
   site-packages (~10 MB) ≈ 120 MB before App Thinning. Audit
   `python-stdlib/` and drop unused submodules (`tkinter`, `test/`,
   `idlelib/`, `turtledemo/`, ensurepip).
