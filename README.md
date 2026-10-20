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
| **Flutter native** | Linux · Windows · Android | `flutter_app/` | **Official non-Apple client** — embedded Rust bindings; legacy bridge sources are compatibility material. Apple platforms use the native Swift client. |

### Native Apple apps

Headless build (no Xcode UI needed):

```bash
mise run mac:build      # builds the AppKit app with embedded Rust FFI
```

Or open the project in Xcode:

```bash
cd ios/EpubToMp3
xcodegen generate
open EpubToMp3.xcodeproj
```

The Apple app calls `converter-core` through `converter-ffi` in-process.
`mise run sidecar:build` builds the separate compatibility HTTP server; it is
not an Apple runtime dependency. Mac compilation uses the project build guard
and one compiler job; preserve compatible artifacts rather than rebuilding them
for inspection.

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

### Platform development

```bash
mise run mac:run                    # native macOS app, Debug
mise run ios:run                    # native iOS app on the paired iPhone, Debug
mise run flutter:run                # explicit Android target on the authorized Android host
mise run flutter:build-linux        # Linux desktop release
mise run flutter:build-windows      # Windows desktop release
mise run flutter:build-apk          # Android (release)
```

Apple development runs on the Mac; Android/Linux development runs on Arch.
Simulator execution on this Mac is quarantined after host panics. An environment
flag does not authorize bypassing that gate. Read the current execution rules in
`CLAUDE.md` before launching targets. Before changing Flutter transport or claiming
runtime parity, read `CONTEXT.md` and inspect `mise run migration:product-boundary-audit`.

---

## Features

The list below spans native and compatibility surfaces; it is not a claim that
every client currently has feature parity. Check the migration audit and the
relevant implementation before relying on a surface-specific behavior.

- **Default narration**: Piper `pt_BR-faber-medium` primary with installed platform speech as fallback. Keep Piper selected and retry at bounded recovery points after fallback; report the provider and voice actually used.
- **Explicit online selection**: Edge requires user selection or consent for online fallback. Models are installed only by an explicit user action. Browser native speech supports listening; browser MP3 conversion/export requires Piper.
- **Audio reuse**: completed chapter audio is reused only after its source and provider identity are validated
- **Chapter structure**: preserves TOC hierarchy (NCX / EPUB3 nav), numbered `1.0 / 1.1 / 1.2`
- **Batch conversion**: the Rust CLI accepts EPUB inputs; format support is surface-specific
- **Web UI**: React browser client with Rust/WASM book processing and local Piper synthesis; the HTTP server remains a compatibility surface
- **Audio validation**: WPM-based truncation detection, auto-retry with engine fallback
- **Progress ETA**: per-chapter telemetry + chunk tracking for accurate estimates

---

## Quick Start

### Recommended (mise)

```bash
git clone https://github.com/pietro1704/Epub-to-Mp3.git
cd Epub-to-Mp3
mise run convert           # Print native CLI usage; the task builds/packages it when needed
```

Select the build/run task for the intended platform in `mise.toml`; avoid setting
up every toolchain for a single client. Native Apple and packaged Rust conversion
do not require a Python runtime. Install a voice model explicitly through the
client or the CLI model command before requesting that voice. On this Mac, use
the guarded tasks and keep Android work on Arch.

### Legacy Python compatibility setup

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

# Preview chapter structure without synthesis
mise run convert -- convert book.epub --show-structure

# Force re-parse (ignore cache)
mise run convert -- convert book.epub --clear-cache

# Batch: multiple files or folder
mise run convert -- convert book1.epub book2.epub --batch ~/epub-folder/

```

The Python CLI remains in `python_app/` as the migration oracle until
differential coverage and the final cutover validation are complete.
PDF conversion is not implemented by the embedded Rust CLI; it reports an
unsupported-format error instead of attempting to parse a PDF as EPUB. Native
reader format support is a separate capability. Unsupported legacy CLI flags
are rejected explicitly; `--verify` verifies the output after conversion.

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
```

The Docker deployment builds `converter-server` and serves the browser bundle.
Its HTTP conversion endpoints are compatibility routes with their own provider
capabilities; they are not required for the browser's local WASM conversion or
for native clients. Python server/entrypoint sources remain compatibility material.

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

| Provider | Role | Requires |
|----------|------|----------|
| **Piper** | Default primary, Faber medium for Brazilian Portuguese | Explicitly installed model and the client's embedded runtime |
| **Platform speech** | Default fallback, preferring installed Luciana on Apple for Brazilian Portuguese | An installed compatible system voice |
| **Edge-TTS** | Explicit online primary or consented online fallback where supported | Internet and user selection/consent |

Preferences are captured per job. A fallback must report its active provider and
voice without silently changing the configured primary. Web platform speech is
for listening only and cannot be used to claim an MP3 export succeeded.

The legacy Python compatibility engine has separate Edge-first configuration,
including `ENGINE_CHAIN_FALLBACK` and `FALLBACK_ENGINE_OVERRIDE`. Those variables
do not define the native app, Rust CLI or browser defaults.

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
├── flutter_app/             # Non-Apple client with embedded Rust bindings
├── web/                     # Local browser WASM/Piper surface and compatibility adapters
├── python_app/              # Python compatibility/migration path
├── hf_app.py                # Legacy Python HF compatibility entrypoint
├── Dockerfile               # Rust server and browser bundle deployment
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
