---
title: EPUB to MP3 Converter
emoji: 📚
colorFrom: blue
colorTo: purple
sdk: docker
pinned: false
license: mit
---

# EPUB to MP3 Converter

Convert EPUB/PDF ebooks into MP3 audiobooks using neural TTS engines.

**Live Demo**: [Hugging Face Space](https://huggingface.co/spaces/pi1704/epub-to-mp3)

---

## Download

Pre-built apps (updated on every release tag):

| Platform | Download |
|---|---|
| **macOS** (Apple Silicon · Intel) | `EpubToMp3-macos-*.zip` from [Releases](https://github.com/pietro1704/Epub-to-Mp3/releases) — unzip and drop into `/Applications` |
| **Linux** (x64) | `EpubToMp3-flutter-linux-*.tar.gz` from [Releases](https://github.com/pietro1704/Epub-to-Mp3/releases) |
| **Windows** (x64) | `EpubToMp3-flutter-windows-*.zip` from [Releases](https://github.com/pietro1704/Epub-to-Mp3/releases) |
| **Android** | `EpubToMp3_android.apk` from [Releases](https://github.com/pietro1704/Epub-to-Mp3/releases) |
| **iOS / iPadOS** (sideload) | Build from `ios/EpubToMp3/` and sideload via AltStore |
| **Docker** | `docker pull ghcr.io/pietro1704/epub-to-mp3:latest` |

---

## Apps

The repository has two native client codebases plus a separate browser/HF
surface. `CONTEXT.md` defines the required local shared-Rust architecture;
source presence is not proof that migration is complete. Check
`mise run migration:product-boundary-audit` for Web/Flutter and
`mise run check:rust-migration` for packaging readiness before claiming a
surface has cut over.

| Surface | Platforms | Where | Status |
|---|---|---|---|
| **Native Apple** | macOS · iPadOS · iOS | `ios/EpubToMp3/` | **Official Apple client** — Library-first reader; follows the local shared Rust conversion contract. |
| **Flutter native** | Linux · Windows · Android | `flutter_app/` | **Official non-Apple client** — single codebase. Its current transport still has legacy HTTP/Python references; verify cutover with the migration audit. macOS/iOS are handled by SwiftUI, not Flutter. |

### Native Apple apps

Headless build (no Xcode UI needed):

```bash
mise run mac:build      # builds the AppKit app with the Rust converter-server sidecar
```

Or open the project in Xcode:

```bash
cd ios/EpubToMp3
xcodegen generate
open EpubToMp3.xcodeproj
```

The `mise run sidecar:build` task builds the embedded Rust server
that the macOS build copies inside the `.app`'s Resources.

#### Build artifact hygiene

Build artifacts are not automatically safe to delete. Before cleanup, inspect
the exact task targets and confirm a directory is inactive, untracked, and not
needed by a running build or release. Preserve `.cache/`, `output/`, models,
jobs, books, and user inputs. Run cleanup tasks only when the user authorizes
that cleanup.

#### iOS companion features

| Feature | Detail |
|---|---|
| **Immersive reader** | Tap the centre of any page to toggle chrome (nav bar + status bar). Auto-hides on page turn. Shared between `InstantReaderView` (local EPUB) and `PlayerReaderView` (server-streamed). |
| **No-autoplay policy** | Audio never starts without an explicit user gesture — lock-screen controls, widget Play button, or in-app Play only. |
| **Live Activity** | Conversion progress displayed on Dynamic Island and lock-screen banner via `ConversionLiveActivityWidget`. Attributes model is `ConversionActivityAttributes` in `EpubToMp3/Models/`. |
| **Widgets** | Home-screen: `NowPlayingWidget` (medium/large). Lock-screen: `NowPlayingLockScreenWidget`. Conversion progress: `ConversionLiveActivityWidget` (Live Activity). |
| **Shared types** | `ConversionActivityAttributes.swift` is compiled into both the main app target and `EpubToMp3Widget` — ActivityKit serialises by name + Codable, so the type must be identical on both sides. |
| **App Group** | `group.com.pietrocode.epubtomp3` — shared `UserDefaults` suite for widget ↔ app state sync (`WidgetDataSync`). |

### Flutter app

```bash
mise run mac:run                    # native macOS app, Debug
mise run ios:run                    # native iOS app on the paired iPhone, Debug
IOS_ALLOW_LOW_RESOURCE_SIMULATOR=1 IOS_TARGET=simulator mise run ios:run # iOS Simulator, Debug (accepts the risk on this Intel 8 GiB Mac)
mise run flutter:run                # Android phone, or the lightest available Android AVD, Debug
mise run flutter:build-linux        # Linux desktop release
mise run flutter:build-windows      # Windows desktop release
mise run flutter:build-apk          # Android (release)
```

The Flutter conversion boundary is migrating. Before changing transport or
claiming parity, read `CONTEXT.md` and run
`mise run migration:product-boundary-audit`.

---

## Features

The list below spans native and compatibility surfaces; it is not a claim that
every client currently has feature parity. Check the migration audit and the
relevant implementation before relying on a surface-specific behavior.

- **Two TTS engines**: Edge-TTS (cloud, multilingual) and Piper (offline ONNX, one model per language). `auto` is an alias for the Edge-first selection.
- **Edge-first by default**: per-chunk single-sentence fallback recovers transient failures and returns to Edge. Opt-in to the legacy Edge → Piper cascade via `--engine-chain-fallback` or `ENGINE_CHAIN_FALLBACK=1`.
- **Smart cache**: parsed text cached per-book — re-runs skip re-parsing
- **Chapter structure**: preserves TOC hierarchy (NCX / EPUB3 nav), numbered `1.0 / 1.1 / 1.2`
- **Batch conversion**: queue multiple EPUB/PDF files or entire folders
- **Web UI**: Browser/HF React surface with legacy HTTP integration; Rust/WASM conversion cutover is tracked by the migration audit
- **Audio validation**: WPM-based truncation detection, auto-retry with engine fallback
- **Progress ETA**: per-chapter telemetry + chunk tracking for accurate estimates

---

## Quick Start

### Recommended (mise)

```bash
git clone https://github.com/pietro1704/Epub-to-Mp3.git
cd Epub-to-Mp3
mise run install        # Sets up the Python 3.12.10 venv, npm, and Piper binary
```

### Manual

```bash
pip install -r requirements.txt
brew install ffmpeg espeak-ng   # macOS; use apt on Linux
```

---

## CLI Usage

```bash
# Native Rust CLI (canonical production entrypoint)
mise run convert -- convert book.epub

# Force a specific engine
mise run convert -- convert book.epub --engine edge
mise run convert -- convert book.epub --engine piper

# Single chapter or range
mise run convert -- convert book.epub --chapter 3
mise run convert -- convert book.epub --chapter 5.1,5.2,5.3

# Preview chapter structure (saves parsed text to cache)
mise run convert -- convert book.epub --show-structure

# Force re-parse (ignore cache)
mise run convert -- convert book.epub --clear-cache

# Batch: multiple files or folder
mise run convert -- convert book1.epub book2.pdf --batch ~/folder/

# Interactive menu (pick engine/voice/settings)
mise run convert -- convert book.epub --menu
```

The Python CLI remains in `python_app/` as the migration oracle until
differential coverage and the final cutover validation are complete.

### Shell Autocomplete (Optional)

```bash
# Zsh (macOS default) — add to ~/.zshrc
echo "source $(pwd)/shell-completion.zsh" >> ~/.zshrc && source ~/.zshrc
```

Tab-completes `.epub`/`.pdf` file paths and `--engine` values.

---

## Web Server

```bash
mise run rust:server                   # Native Rust server (canonical)
mise exec -- cargo run --release -p converter-server # Direct Rust server
```

The Python server and HF entrypoint are compatibility/migration surfaces and
may still back browser/demo flows. They are not the required architecture for
native client conversion. Check the migration audit and current code before
claiming a particular client has stopped using them.

Frontend dev server (hot reload):

```bash
cd web && npm run dev
```

---

## Legacy Python/HF API endpoints

These routes document the compatibility server, not the required client
architecture contract. Do not assume native clients depend on them; inspect
the Rust server and migration audit for the current product path.

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/convert` | Upload EPUB/PDF and start conversion |
| `GET` | `/api/jobs/{job_id}` | Conversion status + SSE progress stream |
| `POST` | `/api/jobs/{job_id}/cancel` | Cancel a queued/running job |
| `GET` | `/api/outputs/{job_id}/{filename}` | Download MP3 / ZIP |
| `GET` | `/api/voices` | Curated voice list for the frontend |
| `GET` | `/api/telemetry` | Aggregated engine throughput (chars/s) |
| `GET` | `/api/health` | Health check |
| `GET` | `/api/sessions` | Conversion session log |
| `DELETE` | `/api/sessions` | Clear session log |

Uploads are capped at **100 MB** by default. Override:

```bash
export MAX_UPLOAD_MB=200          # backend
export VITE_MAX_UPLOAD_MB=200     # frontend build
```

---

## Key Environment Variables

### Legacy Python/HF Edge-TTS tuning

```bash
EDGE_CHUNK_CHARS=12000           # Characters per request
EDGE_MAX_CONCURRENCY=12          # Parallel requests (HF: 1)
EDGE_MAX_SEGMENT_SECONDS=85      # Max audio segment duration
CHAPTER_PARALLEL_COUNT=0         # 0 = auto-detect from CPU cores
```

### Legacy Python/HF engine fallback thresholds

```bash
EDGE_MIN_CHARS_PER_SECOND=45     # Example local slow-mode trigger (HF differs)
EDGE_SLOW_RATIO_THRESHOLD=2.5    # Example local elapsed/estimated ratio (HF differs)
```

### Legacy Python/HF oversized-chapter handling

```bash
MAX_CHAPTER_CHARS=0              # Skip chapters larger than N chars (0 = disabled)
                                  # Auto-warns when a chapter is >5× median size
```

### Legacy Python/HF local engine

```bash
PIPER_MAX_PROCS=0                # 0 = auto-detect from CPU
```

---

## Development

```bash
mise run test           # Python unit/integration + Web lint/tests/build; not a full Rust/Flutter/Apple gate
mise run test:unit      # Python unit tests only
mise run test:web       # Web lint + tests + build
mise run clean          # Potentially destructive; inspect targets, back up first, and run only when explicitly requested
mise run trim-log       # Trim conversions.jsonl to last 500 entries
mise run hooks-test     # Validate Claude Code hook scripts
mise run audit          # Scan Python dependencies for CVEs
```

`mise run test` does not certify Rust, Flutter, or Apple behavior. Inspect
`mise.toml` and use the surface-specific validation required by the change.

---

## TTS Engine Details

| Engine | Languages | Quality | Speed | Requires |
|--------|-----------|---------|-------|----------|
| **Edge-TTS** | All | ⭐⭐⭐ | Fastest | Internet |
| **Piper** | pt, en, es, fr, de, it | ⭐⭐ | Moderate | Piper binary + ONNX model |

**Default behavior (CLI + web):** Edge-first. Per-chunk failures are retried as a single sentence and synthesis returns to Edge. Piper is available when its binary and model are installed.

**Optional legacy cascade:** set `ENGINE_CHAIN_FALLBACK=1` (or pass `--engine-chain-fallback` on the CLI) to enable Edge → Piper fallback. Use `FALLBACK_ENGINE_OVERRIDE=piper|none|auto` to control that offline tier.

---

## Available Voices

### Edge-TTS (pt-BR)
- **Female**: Francisca, Brenda, Elza, Giovanna, Leila, Leticia, Manuela, Yara, Thalita
- **Male**: Antonio, Donato, Fabio, Humberto, Julio, Nicolau, Valerio

### Piper (local, pt-BR)
- `pt_BR-faber-medium` (recommended)
- `pt_BR-edresson-low`

---

## Project Structure

```
Epub-to-Mp3/
├── CONTEXT.md               # Product contract and domain vocabulary
├── Cargo.toml / crates/     # Shared Rust runtime, CLI, server, FFI and WASM
├── mise.toml                # Tool versions and authoritative task definitions
├── ios/EpubToMp3/           # Native Apple client
├── flutter_app/             # Non-Apple client; transport migration in progress
├── web/                     # Browser surface; WASM plus legacy integration
├── python_app/              # Python compatibility/migration path
├── hf_app.py / Dockerfile   # HF compatibility/demo deployment
├── docs/adr/                # Accepted architecture decisions
└── scripts/                 # Audits, validation and build helpers
```

---

## HF Spaces

The Space runs via Docker. GitHub CI syncs code → HF rebuilds the image.

Key auto-applied settings when `SPACE_ID` is set:
- `EDGE_MAX_CONCURRENCY=1`, `CHAPTER_PARALLEL_MAX=1` (shared CPU)
- `EDGE_MIN_CHARS_PER_SECOND=100`; timeout behavior is selected by the HF runtime profile
- `COMPLETED_JOB_TTL_HOURS=48` (outputs survive overnight on `/data`)

Persistent storage at `/data/epub-to-mp3/` survives Space restarts.

---

## License

MIT
