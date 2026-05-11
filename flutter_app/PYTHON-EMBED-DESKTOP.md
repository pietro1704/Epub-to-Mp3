# Python on Linux + Windows desktop (system Python 3.10+)

The Flutter desktop targets (`flutter build linux` / `flutter build
windows`) reuse the same `python_app/src/...` pipeline as the iOS app
(PythonKit), the Android app (Chaquopy), the macOS SwiftUI sidecar, and
the HF Spaces backend.

On desktop we deliberately do **not** embed CPython into the bundle.
v1 uses the user-installed system Python — this trades a ~30 MB bundle
for a one-time install requirement (`apt install python3` /
`winget install Python.Python.3.13`). Linux + Windows desktop is < 5 %
of users; embedded CPython is documented below as a future follow-up.

> macOS / iOS: not supported. Apple platforms are owned by the SwiftUI
> app in `ios/EpubToMp3/`.

## Architecture

```
┌────────────────────────────┐
│ Flutter / Dart             │
│  PythonBridge              │  ← lib/services/python_bridge.dart
└──────────────┬─────────────┘
               │ Process.start(python3, ['-c', ...])
┌──────────────▼─────────────┐
│ System CPython 3.10+       │
│  python_app.src.…          │  ← extracted from Flutter assets to
│  └─ android_entrypoints    │     <app-support>/python_app/ on first run
└────────────────────────────┘
```

The same `parse_epub_to_json(path)` entrypoint serves Android (Chaquopy)
and desktop (subprocess). No `desktop_entrypoints.py` exists — one
function, two callers.

## Setup

```bash
# 1. Sync python_app/src/ into flutter_app/assets/python_app/src/.
mise run desktop:bootstrap-python

# 2. Build the desktop bundle. Must run on the target OS — Flutter does
#    not cross-compile Linux/Windows desktop bundles from macOS.
mise run flutter:build-linux    # on a Linux host
mise run flutter:build-windows  # on a Windows host
```

The `flutter_app/assets/python_app/` directory is **gitignored** —
regenerate via the script whenever `python_app/src/*` changes.

## Bridge contract

`PythonBridge.isSupported` is `true` on Android **and** on Linux /
Windows desktop hosts. The Dart API surface is identical across
platforms:

| Method      | Args                                  | Returns                                            |
|-------------|---------------------------------------|----------------------------------------------------|
| `bootstrap` | _none_                                | `String` — Python `sys.version`                    |
| `parseEpub` | `path: <absolute EPUB/PDF>`           | `EbookFulltext` matching `FulltextChapter` schema  |

`convertChapter` is **not yet wired** — same scope as the Android slice.

## Python invocation contract (desktop)

The bridge picks a Python executable via probing, in this order:

* Linux: `python3`, `python`
* Windows: `python`, `python3`, `py`

Each candidate is probed with `--version`; the first one reporting
Python ≥ 3.10 wins. Missing / too-old Python surfaces a clear
[StateError] guiding the user to install from python.org or their
distro package manager.

`parseEpub` invocation (file path passed via stdin to avoid shell-quoting
issues with non-ASCII paths):

```bash
python3 -c '
import sys, os
sys.path.insert(0, os.environ["PYTHONPATH"])
path = sys.stdin.read()
from python_app.src.android_entrypoints import parse_epub_to_json
sys.stdout.write(parse_epub_to_json(path))
'
```

Environment:

* `PYTHONPATH` = the parent of the extracted `python_app/` (so
  `from python_app.src... import ...` resolves).
* `PYTHONUNBUFFERED=1`, `PYTHONIOENCODING=utf-8`.

On first call the bridge extracts every asset under
`assets/python_app/` from the Flutter bundle into the OS app-support dir
(`getApplicationSupportDirectory()`), marks it with a `.bootstrapped`
sentinel, and reuses the same directory on later runs.

## Known risks

* **edge-tts / aiohttp not installed by default.** The system Python
  used here is whatever the user has on PATH. For `parseEpub` (parser
  only) this is fine — `ebook_reader.py` depends only on the stdlib +
  `ebooklib` + `lxml`, both of which need to be `pip install`-ed
  user-side before the conversion path lands.
* **Per-call subprocess overhead.** ~50–150 ms cold start per
  invocation. Acceptable for `parseEpub`; for streaming TTS we'll need
  a long-lived subprocess or named pipe.
* **Antivirus / smartscreen on Windows.** `Process.start` of an
  unsigned `python.exe` may prompt on locked-down corporate machines.

## Future: embedded CPython (zero-install)

Two viable paths once we want to drop the user-side Python install:

1. **Windows**: ship the official
   [embeddable package](https://docs.python.org/3/using/windows.html#the-embeddable-package)
   alongside `python.exe` inside the Flutter `runner.exe` bundle.
2. **Linux**: bundle via AppImage with a relocatable Python (e.g.
   [python-build-standalone](https://github.com/indygreg/python-build-standalone)).

Both are mechanical extensions of the current architecture — the bridge
just picks the bundled `python` binary instead of probing the system.
