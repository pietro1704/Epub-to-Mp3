# Embedded Python on Android (Chaquopy)

The Flutter Android app embeds **CPython 3.13** inside the APK via
[Chaquopy](https://chaquo.com/chaquopy/) so it can reuse the exact same
pipeline modules (`python_app/src/…`) that power the iOS app, the macOS
sidecar, and the HF Spaces backend.

This document mirrors `ios/PYTHON-EMBED.md` — read both side-by-side if
you're cross-referencing the two clients.

## Architecture

```
┌────────────────────────────┐
│ Flutter / Dart             │
│  PythonBridge              │  ← lib/services/python_bridge.dart
└──────────────┬─────────────┘
               │ MethodChannel('epub_to_mp3/python')
┌──────────────▼─────────────┐
│ Android / Kotlin           │
│  MainActivity              │  ← android/app/src/main/kotlin/.../MainActivity.kt
│   └─ Chaquopy              │
└──────────────┬─────────────┘
               │ Python.getInstance().getModule(...)
┌──────────────▼─────────────┐
│ CPython 3.13 (embedded)    │
│  python_app.src            │  ← bootstrap-android-python.sh mirrors here
│   └─ android_entrypoints   │  ← parse_epub_to_json / bootstrap
│   └─ ebook_reader, …       │
└────────────────────────────┘
```

Unlike iOS, Chaquopy **bundles `_socket` and `_ssl`**, so `aiohttp` and
`edge_tts` run in-process unmodified. No Swift / Kotlin network bridge
is required.

## Setup

```bash
# 1. Sync python_app/src/ into android/app/src/main/python/
mise run android:bootstrap-python

# 2. Build the APK — the first build downloads CPython runtimes
#    + pip-installs edge-tts + aiohttp (one-time, cached afterwards).
mise run flutter:build-apk-debug
```

The generated source set under `flutter_app/android/app/src/main/python/`
is **gitignored** — re-run the bootstrap script whenever you change
`python_app/src/*`.

## APK size

Expect roughly **~150 MB** for the debug APK once Chaquopy bundles
CPython + the standard library + `edge_tts` + `aiohttp` for the ABIs
listed in `build.gradle.kts` (`arm64-v8a`, `x86_64`).

Future optimisation paths:

- Drop `x86_64` for release builds (saves ~30 MB).
- Use Chaquopy's `pyc.src = false` to ship `.pyc` only.
- Trim the standard library via Chaquopy's `extractPackages` if/when
  startup speed matters more than the size win.

## Bridge contract

The MethodChannel is named `epub_to_mp3/python`. Methods exposed today:

| Method      | Args                                  | Returns                                            |
|-------------|---------------------------------------|----------------------------------------------------|
| `bootstrap` | _none_                                | `String` — Python `sys.version`                    |
| `parseEpub` | `{ "path": <absolute EPUB/PDF path> }`| `String` — JSON matching `EbookFulltext.fromJson`  |

`convertChapter` is intentionally **not** wired yet — it depends on
`python_app.src.converter.synthesize_chapter_via_transport`, which the
iOS embed branch adds in parallel. Once that lands on `master`, wire it
through here using the same channel name.

## Known AGP / Chaquopy version pin

Chaquopy 16.1.0 has only been tested by upstream against AGP ≤ 8.7. The
Flutter scaffold currently pins **AGP 8.11.1** in
`android/settings.gradle.kts`. With that pairing, `flutter build apk`
fails during plugin application with:

```
Failed to apply plugin 'com.chaquo.python'.
   > Failed to find plugin com.android.tools.build:gradle
```

Two ways to unblock once we want a real APK:

1. **Pin AGP to 8.7.x** in `settings.gradle.kts` (preferred — confirmed
   working with Chaquopy 16.x). Flutter Gradle plugin works fine with
   AGP 8.7.
2. Wait for **Chaquopy 16.2+** which adds AGP 8.11 support per the
   upstream roadmap.

Until one of those lands, all bridge-side work (Kotlin
`MainActivity.kt`, Dart `PythonBridge`, Python `android_entrypoints`,
tests) is in place and verified independently — only the actual
compile-into-APK step is blocked.

## Test gap

The Dart tests under `flutter_app/test/python_bridge_test.dart` mock the
MethodChannel so they pass in headless `flutter test`. Real Python
execution can only be verified against an Android emulator or device —
see `flutter_app/README.md` for the validation checklist.
