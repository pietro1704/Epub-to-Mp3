# Architecture

## High-level view

The project is split into four layers:

1. `python_app/`: backend and conversion pipeline
2. `web/`: React/TypeScript frontend
3. `ios/EpubToMp3/`: SwiftUI client (macOS · iPadOS · iOS) with embedded PyInstaller sidecar on macOS
4. `flutter_app/`: Flutter client (Linux · Windows · Android)

## Two conversion pipelines

There is a critical design detail:

- `python_app/src/converter.py`: CLI pipeline
- `python_app/server.py`: Web/API pipeline

They are separate. Relevant behavior changes must be mirrored across both paths when applicable.

## Backend

Main files:

- `python_app/main.py`: CLI entrypoint
- `python_app/server.py`: FastAPI API
- `python_app/src/config.py`: conversion configuration
- `python_app/src/ebook_reader.py`: EPUB/PDF parsing
- `python_app/src/cache_manager.py`: per-book/per-chapter cache
- `python_app/src/job_manager.py`: job persistence and queue
- `python_app/src/tts/`: TTS engines

## Frontend

Main files:

- `web/src/App.tsx`: main composition
- `web/src/hooks/useConversionFlow.ts`: conversion state machine
- `web/src/services/ConversionService.ts`: HTTP/SSE/polling client
- `web/src/i18n/translations.ts`: translations

## Native clients

- `ios/EpubToMp3/project.yml`: xcodegen project descriptor; the `Embed Python sidecar (macOS only)` post-build script copies `dist/epub-to-mp3-server` into the `.app` Resources
- `flutter_app/lib/`: Flutter client source (Linux · Windows · Android)
- `desktop.spec`: PyInstaller spec for the sidecar binary built via `mise run sidecar:build`
