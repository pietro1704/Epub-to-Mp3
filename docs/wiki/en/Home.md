# Wiki: EPUB to MP3

Convert EPUB/PDF ebooks into MP3 audiobooks with multiple TTS engines, automatic fallback, per-book caching, a real-time web UI, a SwiftUI app for Apple platforms, and a Flutter app for Linux/Windows/Android.

## Overview

The project supports four main usage modes:

- `CLI`: local terminal conversion
- `Web`: FastAPI backend plus React frontend
- `Apple` (`ios/EpubToMp3/`): SwiftUI app for macOS / iPadOS / iOS; macOS embeds the Python sidecar
- `Non-Apple` (`flutter_app/`): Flutter app for Linux / Windows / Android

By default, local CLI and web mode share the same persistent directories:

- `.cache/` for parsed text and intermediate artifacts
- `output/` for MP3s, ZIP files, and final outputs
- `.jobs/` for web job metadata
- `.uploads/` for uploaded files

## Quick links

- [Getting Started](./Getting-Started.md)
- [CLI and Web Usage](./CLI-and-Web.md)
- [Desktop, Mobile, and Releases](./Desktop-Mobile-and-Releases.md)
- [Architecture](./Architecture.md)
- [Configuration and Performance](./Configuration-and-Performance.md)
- [Deployment and Hugging Face Spaces](./Deployment-and-HF-Spaces.md)
- [Troubleshooting](./Troubleshooting.md)
- [Contributing and Security](./Contributing-and-Security.md)

## Main features

- `EPUB` and `PDF` to `MP3` conversion
- Fallback chain across `Edge-TTS`, `Kokoro`, and `Piper`
- Table of contents and chapter hierarchy preservation
- Aggressive caching to avoid repeated parsing
- Progressive playback while chunks are synthesized
- Per-chapter download and full ZIP download
- Native macOS app (SwiftUI) with embedded Python sidecar
- Native Linux / Windows / Android apps (Flutter)
- iOS / iPadOS sideloadable archive

## Core stack

- Backend: `Python`, `FastAPI`
- Frontend: `React`, `TypeScript`, `Vite`
- Apple client: `SwiftUI`
- Non-Apple client: `Flutter`
- CI/CD: `GitHub Actions`
- Public demo: `Hugging Face Spaces`
