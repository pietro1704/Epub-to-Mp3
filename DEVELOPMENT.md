# Development Guide

## Quick Start

### Using mise (Recommended)

```bash
# Install dependencies
mise run python:install
mise run web:install

# Run development servers (auto-copies test fixtures)
mise run dev

# Build for production (auto-copies test fixtures)
mise run web:build

# Run tests
mise run python:test
mise run web:test
```

### Using npm

```bash
# Install all dependencies
npm run install:all

# Run development servers
npm run dev

# Build for production (auto-copies test fixtures)
npm run build

# Run tests
npm test
```

## Test Fixtures

The project uses a **single source** EPUB for testing, located at:
- `python_app/tests/fixtures/epubs/test_multifeature.epub`

This file is automatically copied to `web/public/sample.epub` during:
- ✅ `mise run dev` - Before starting dev servers
- ✅ `mise run web:dev` - Before starting web dev server
- ✅ `mise run web:build` - Before building web
- ✅ `npm run build` - Before building web
- ❌ `npm run dev` - Does NOT auto-copy (use mise for dev)

### Manual Sync

If needed, manually copy fixtures:

```bash
# Using mise
mise run sync:fixtures

# Using script directly
./sync_test_fixtures.sh
```

## Architecture

### Backend (Python)
- FastAPI server at `python_app/server.py`
- TTS engines: Edge-TTS, Coqui, Piper
- Multi-language support with `[[lang:xx]]` tags
- Location: `python_app/src/`

### Frontend (React + Vite)
- React 18 + TypeScript
- Real-time conversion status
- Downloads panel
- Location: `web/src/`

### Multi-Language Support

EPUBs can have `lang` attributes that are converted to internal tags:

```html
<!-- Source EPUB -->
<p lang="en">Hello</p>
<p lang="es">Hola</p>

<!-- Processed internally -->
[[lang:en]]Hello[[/lang]]
[[lang:es]]Hola[[/lang]]
```

The TTS engine (Edge-TTS) uses different voices per language automatically.

## Project Structure

```
.
├── python_app/
│   ├── src/                    # Core conversion logic
│   │   ├── tts/               # TTS engine implementations
│   │   ├── ebook_reader.py    # EPUB/PDF parsing
│   │   └── converter.py       # Main conversion pipeline
│   ├── tests/
│   │   └── fixtures/epubs/    # ← SOURCE test EPUBs
│   ├── server.py              # FastAPI server
│   └── main.py                # CLI entry point
├── web/
│   ├── src/                   # React frontend
│   └── public/
│       └── sample.epub        # ← Generated from fixtures
├── sync_test_fixtures.sh      # Fixture copy script
└── .mise.toml                 # Task runner config
```

## Common Tasks

### Add a new TTS engine

1. Create `python_app/src/tts/new_engine.py`
2. Implement `synthesize_async()` method
3. Register in `python_app/src/tts/factory.py`

### Modify test EPUB

1. Edit `python_app/tests/fixtures/epubs/test_multifeature.epub`
2. Run `mise run sync:fixtures` to copy to public
3. Or just run `mise run dev` (auto-copies)

### Run specific tests

```bash
# All tests
mise run python:test

# Specific test file
pytest python_app/tests/test_epub_multifeature.py -v

# Specific test
pytest python_app/tests/test_epub_multifeature.py::TestLanguageAttributeExtraction -v
```

## Git Workflow

The `.gitignore` is configured to:
- ✅ Track `python_app/tests/fixtures/epubs/*.epub` (source)
- ❌ Ignore `web/public/sample.epub` (generated)
- ❌ Ignore other `*.epub` files

This ensures:
- Test fixtures are versioned
- Generated files are not committed
- Clean git status

## Troubleshooting

### "sample.epub not found" in web/public

Run the sync script:
```bash
mise run sync:fixtures
```

### Tests failing with fixture not found

Ensure fixtures exist:
```bash
ls python_app/tests/fixtures/epubs/
# Should show: test_multifeature.epub, sample_multilang.epub
```

### Multi-language audio not working

1. Check EPUB has `lang` attributes: `unzip -p test.epub chapter.xhtml | grep lang`
2. Verify tags extracted: Run CLI with `--verbose`
3. Check Edge-TTS voice support: Different voices for each language

## Documentation

- `python_app/tests/fixtures/epubs/README.md` - Fixture documentation
- `python_app/CLAUDE.md` - AI assistant context
- `web/README.md` - Frontend documentation
