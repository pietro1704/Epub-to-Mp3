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
The Rust HTTP server (`converter-server`) is not an Apple runtime dependency. Mac compilation uses the project build guard
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
| **Immersive reader** | Tap the reader centre to toggle chrome. The UIKit reader uses [MainReaderScreenController](ios/EpubToMp3/EpubToMp3/Features/Reader/Views/MainReaderScreenController.swift) to host [BookOpenScreenController](ios/EpubToMp3/EpubToMp3/Features/Reader/Views/BookOpenScreenController.swift); see [chrome transitions](ios/EpubToMp3/docs/reader-chrome-animation.md). |
| **No-autoplay policy** | Audio never starts without an explicit user gesture — lock-screen controls, widget Play button, or in-app Play only. |
| **Live Activity** | Conversion progress on the lock screen and, on supported devices, Dynamic Island via `ConversionLiveActivityWidget` (iOS 16.2+). Shared attributes are defined in [ConversionActivityAttributes.swift](ios/EpubToMp3/EpubToMp3/Shared/Integrations/ConversionActivityAttributes.swift). |
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
Host guards and the Simulator quarantine on this Mac were removed on 2026-11-22
(the host had earlier panics). Read the current execution rules in
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
- **Web UI**: Rails (Hotwire) client in `ruby_app/rails_gateway` with Rust/WASM book processing and local Piper synthesis in the browser; the HTTP server remains a compatibility surface
- **Audio validation**: WPM-based truncation detection, auto-retry with engine fallback
- **Progress ETA**: per-chapter telemetry + chunk tracking for accurate estimates

---

## Quick Start

### Recommended (mise)

```bash
git clone https://github.com/pietro1704/Epub-to-Mp3.git
cd Epub-to-Mp3
mise run convert           # Build/package the native CLI, then print usage
```

Select the build/run task for the intended platform in `mise.toml`; avoid setting
up every toolchain for a single client. Install a voice model explicitly through the
client or the CLI model command before requesting that voice. On this Mac, use
the guarded tasks and keep Android work on Arch.
The `convert` task invokes the build and packaging path even for usage output;
inspect its prerequisites before running it as a help command.

---

## CLI Usage

```bash
# Native Rust CLI (canonical production entrypoint; ./convert is a shortcut)
mise run convert -- convert book.epub
./convert book.epub

# Force a specific engine
mise run convert -- convert book.epub --engine edge
mise run convert -- convert book.epub --engine piper

# One zero-based position, or repeated literal chapter IDs
mise run convert -- convert book.epub --chapter position:2
mise run convert -- convert book.epub --chapter 5.1 --chapter 5.2 --chapter 5.3

# Preview chapter structure without synthesis
mise run convert -- convert book.epub --show-structure

# Batch: multiple files or folder
mise run convert -- convert book1.epub book2.epub --batch ~/epub-folder/

```

The native CLI converts EPUB and text-layer PDF; see the
[PDF contract](docs/pdf-conversion.md). A book name that matches no file is
looked up by fuzzy title in `~/Downloads`. Reader format support is a separate
capability. Unsupported legacy CLI flags are rejected explicitly; `--verify`
verifies the output after conversion.

Chapter selections are literal values; use repeated `--chapter` options rather
than a comma-separated list. `position:N` explicitly selects a zero-based
position. Inspect the source structure before selecting chapter IDs.

Cache clearing is destructive: with a book conversion, `--clear-cache` removes
`<cache_dir>/<source_hash>` and any `<output_dir>/<input_file_stem>` directory
without an additional prompt. The worker's job-ID output directories are a
separate layout. Inspect the targets and preserve required audio before an
intentionally authorized clear.

---

## Web Server

```bash
mise run rust:server                   # Native Rust server (canonical)
```

The root `Dockerfile` builds the Rails web client (it does not include
`converter-server`). The `converter-server` HTTP conversion endpoints are
compatibility routes with their own provider capabilities; they are not
required for the browser's local WASM conversion or for native clients.

Rails web client (the WASM runtime is generated, never committed):

```bash
mise run rails:web:runtime-build       # generated Rust/WASM + TTS runtime tree
mise run rails:web:test                # Rails and browser-runtime tests
mise run dev                           # Rails web client on :3000 (DEV_RUST_SERVER=1 adds the Rust server)
```

See [ruby_app/rails_gateway/README.md](ruby_app/rails_gateway/README.md).

---

## HTTP API

`converter-server` routes are defined in
[crates/converter-server/src/main.rs](crates/converter-server/src/main.rs)
(health, contract, uploads, conversion jobs with progress stream, cancel,
resume, outputs and chapter streams). Uploads are capped at 100 MB. The
browser's local WASM conversion and the native clients do not depend on them.

---

## Development

```bash
mise run test           # Rails web tests (Ruby and browser runtime); not a full Rust/Flutter/Apple gate
mise run hooks-test     # Validate Git hooks and the host workflow gate
mise run audit          # Scan npm dependencies for CVEs
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

See the [repository map](docs/repository-map.md) for subsystem ownership,
canonical documentation, generated/vendor boundaries and historical records.

```
Epub-to-Mp3/
├── CONTEXT.md               # Product contract and domain vocabulary
├── Cargo.toml / crates/     # Shared Rust runtime, CLI, server, FFI and WASM
├── mise.toml                # Tool versions and authoritative task definitions
├── ios/EpubToMp3/           # Native Apple client
├── flutter_app/             # Non-Apple client with embedded Rust bindings
├── ruby_app/rails_gateway/  # Rails web client; conversion runs in the browser (Rust/WASM + Piper)
├── Dockerfile               # Rails web image (Hugging Face Space)
├── docs/adr/                # Accepted architecture decisions
└── scripts/                 # Audits, validation and build helpers
```

---

## HF Spaces

The Space runs the Rails web image via Docker. GitHub CI publishes a
`scripts/hf_snapshot.rb` snapshot (`.hf-runtime` is `rails`) and HF rebuilds the image from the root `Dockerfile`.

Key settings `converter-server` auto-applies when `SPACE_ID` is set (the Rails Space image does not run `converter-server`; they matter only where it is deployed):
- `EDGE_MAX_CONCURRENCY=1`, `CHAPTER_PARALLEL_MAX=1` (shared CPU)
- `EDGE_MIN_CHARS_PER_SECOND=100`; timeout behavior is selected by the HF runtime profile
- `COMPLETED_JOB_TTL_HOURS=48` (outputs survive overnight on `/data`)

With a persistent mount, `/data/epub-to-mp3/` survives restarts of a `converter-server` deployment. The Rails interface needs no server state (see the ADR, section 3.7).

---

## License

MIT
