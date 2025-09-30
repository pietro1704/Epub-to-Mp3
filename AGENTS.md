# Repository Guidelines

## Project Structure & Module Organization
- `python_app/` contains the Python package used both by the CLI and the backend service. Key modules live in `python_app/src/` (converter, ebook parsing, TTS engines) and pytest cases reside in `python_app/tests/`.
- `web/` hosts the Vite-based frontend for Cloudflare Pages; builds land in `web/dist` and should not be versioned.
- `python_app/models/` ships bundled Piper ONNX voices; do not rename without updating discovery logic.
- Root-level files (`README.md`, `CLAUDE.md`, `AGENTS.md`, `pytest.ini`) provide documentation and repository-wide settings.

## Build, Test, and Development Commands
- `pip install -r python_app/requirements.txt` — installs the pinned dependency set for all engines.
- `python -m python_app.main <book.epub>` — runs the interactive CLI entry point.
- `python python_app/convert <book.epub> [flags]` — shortcut script for scripted conversions (supports `--engine`, `--parallel`, `--clear-cache`).
- `pytest` — executes the full automated suite; assumes FFmpeg/tts dependencies when audio tests are enabled.
- `cd web && npm install && npm run dev` — starts the Cloudflare Pages frontend locally (set `VITE_API_BASE` to the backend URL when needed).

## Coding Style & Naming Conventions
- Follow standard PEP 8 with 4-space indentation and descriptive snake_case identifiers.
- Prefer dataclasses for configuration objects and keep public APIs typed with `typing` hints.
- Use `pathlib.Path` for filesystem work and rely on helpers such as `FileManager` for sanitising filenames.
- When editing documentation, mirror existing bilingual sections (English first, Portuguese second).

## Testing Guidelines
- Test suite is powered by `pytest`; individual modules can be targeted via `pytest python_app/tests/test_converter.py -k <pattern>`.
- New tests should live alongside peers in `python_app/tests/` and follow the `test_<area>.py` naming scheme with `Test*` classes and `test_*` methods.
- Aim to cover new branches in converters, ebook parsing, and TTS factories; prefer lightweight fixtures and reuse packaged samples in `tests/fixtures/`.

## Commit & Pull Request Guidelines
- Write commit subjects in the imperative mood (e.g., “Refine Piper model discovery”) and keep body lines wrapped to 72 characters when additional context is required.
- Reference related issues using `Fixes #123` or `Refs #123` when applicable.
- Pull requests should include: summary of changes, testing evidence (`pytest` output or manual validation notes), and screenshots or audio logs only when behaviour changes are user-facing.
- Request review from maintainers familiar with TTS or ebook parsing when touching those subsystems.
