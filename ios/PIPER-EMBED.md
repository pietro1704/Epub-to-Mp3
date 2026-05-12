# Piper on iOS — embed plan

Status: **stub-only seam installed**. Slice 1b lands the Python +
Swift wiring so that ``fallback_engine="piper"`` can be requested
through `convert_epub` and `PiperBridge.swift` gets called for every
chunk. Synthesis itself is not implemented — `PiperBridge.synthesize`
always throws `PiperBridgeError.notImplemented`.

Why a stub? Three C dependencies have to be cross-compiled for iOS
arm64 (device) + iOS arm64 simulator slices before Piper can run
in-process. None of them are vendored today (see
`.claude/agent-memory/tts-engine-engineer/project_ios_piper_prereqs.md`).
Each one is its own slice:

| Dep | Why we need it | Source | Notes |
|---|---|---|---|
| onnxruntime | Run the Piper `.onnx` voice model | `onnxruntime-objc` SPM package | Easiest of the three — Microsoft ships an iOS-supported package. |
| espeak-ng | Convert text → phoneme IDs Piper expects | github.com/espeak-ng/espeak-ng | C library, no iOS build in the wild. Must produce a static lib + bundled data dir. |
| lame | Encode Piper's float-array audio → MP3 | github.com/rbrito/lame | The Edge transport contract is *MP3 bytes*; Piper's native output is WAV float arrays. We either encode here or rewrite the contract. |

## Architecture (target)

```
Swift                                    Python
─────                                    ──────
PiperBridge.synthesize(text, language)
  │
  ├─ espeak-ng → phoneme IDs (int[])
  │
  ├─ onnxruntime: load Vendor/piper-models/<lang>/<voice>.onnx,
  │              run inference → float[] audio @ 22.05kHz
  │
  ├─ lame encode float[] → MP3 bytes
  │
  └─ return Data ─────────────────────────► _piper_transport.synthesize_chunk
                                            (called from ios_entrypoints.synthesize_chapter_via_transport
                                             when Edge transport fails for a chunk)
```

`_piper_transport.py` mirrors `_edge_transport.py`: a single
`set_transport(fn)` swap point Swift wires into `PythonEmbed.bootstrap`.

## Stub status (slice 1b, this commit)

What is wired:
- `python_app/src/tts/_piper_transport.py` — Python seam. `synthesize_chunk` raises `RuntimeError("piper transport not installed; see ios/PIPER-EMBED.md")` if no transport is set.
- `python_app/src/ios_entrypoints.py` — `convert_epub` now accepts `fallback_engine="piper"` **only when a transport is installed**. Otherwise raises `"piper fallback requested but no piper transport installed — see ios/PIPER-EMBED.md"`.
- `synthesize_chapter_via_transport` — per-chunk: if Edge transport raises or returns empty bytes and `piper_fallback_lang` was passed, retry via `_piper_transport.synthesize_chunk`.
- `ios/EpubToMp3/EpubToMp3/Services/PiperBridge.swift` — Swift stub. Languages `pt-BR`, `en-US` declared in `PiperBridgeLanguage`. Every call throws `PiperBridgeError.notImplemented`.
- `PythonEmbed.installPiperTransport()` — installs `PiperBridge` as the Python transport at boot, alongside `installEdgeTransport()`. The install succeeds (seam is live) but every call still throws.

Net effect: the wiring exists end-to-end. Edge stays the only TTS that actually produces audio on iOS today. The moment one of the bring-up slices below lands, the relevant `notImplemented` branch is replaced — no contract changes upstream.

## Bring-up slices (future)

Each slice gets its own commit + PR. Naming convention preserved so
they line up in `git log`:

1. **`1c-bringup-onnxruntime`** — add `onnxruntime-objc` SPM dep,
   write a tiny `PiperONNXRunner` Swift class that can load
   `Vendor/piper-models/<lang>/*.onnx`, feed dummy phoneme IDs, and
   return a float buffer. Test: assert non-zero output for a fixed
   seed.
2. **`1c-bringup-espeak`** — cross-compile espeak-ng as a static
   library for iOS device + simulator slices, bundle
   `espeak-ng-data/` into `Vendor/espeak-ng/`. Wrap the C API in a
   Swift class `EspeakPhonemizer.phonemize(text, lang) -> [Int]`.
   Test: known input → known phoneme IDs (cross-checked against the
   linux build).
3. **`1c-bringup-lame`** — cross-compile lame as a static library
   for iOS device + simulator slices. Wrap as `MP3Encoder.encode
   (samples: [Float]) -> Data`. Test: encode a 1s sine wave, assert
   ID3-less MP3 header.
4. **`1c-piper-integration`** — replace `PiperBridge.synthesize`'s
   `.notImplemented` with the full pipeline: espeak-ng → onnxruntime
   → lame. Reuse the existing XCTests in `PiperBridgeTests.swift`;
   they'll start passing without changes (engine gate stays the
   same). Drop the "stub-only" language in this doc.

## How to update models

Slice 1b's plan is to ship two medium-quality voices:
- `pt-BR-faber-medium` (~40 MB)
- `en-US-amy-medium` (~40 MB)

Both come from `huggingface.co/rhasspy/piper-voices`. Run:

```bash
ios/EpubToMp3/scripts/fetch-piper-models.sh
```

The script caches downloads under `~/.cache/epub-to-mp3/piper-voices/`
and copies them into `ios/EpubToMp3/Vendor/piper-models/<lang>/`. The
vendor tree is **gitignored** (see `.gitignore`). To force a re-fetch:

```bash
FORCE=1 ios/EpubToMp3/scripts/fetch-piper-models.sh
```

When the bring-up slices land, this script will become a build-time
dependency of `mac:build` (similar to `bootstrap-ios-python.sh`).

## IPA size budget

Once all four bring-up slices land:
- ~80 MB of C-extension static libs (onnxruntime + espeak-ng + lame)
- ~80 MB of `.onnx` voice models
- = ~160 MB of additional IPA size, plus the existing ~150 MB
  Python.xcframework + stdlib + site-packages (slice 1a).

We may eventually want to split the language models out of the IPA
and download them on first run. That decision is deferred until at
least one full bring-up cycle is done and we have a real binary to
measure.
