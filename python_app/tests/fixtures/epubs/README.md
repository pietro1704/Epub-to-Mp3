# Test Fixtures - EPUB Files

This directory contains the **source** EPUB files used for testing.

## Files

- `test_multifeature.epub` - **SOURCE** main test EPUB with multi-language support
- `sample_multilang.epub` - Alias for the same file (used by multilang tests)

## Build Process

**These files are the SOURCE**, not copies. During build/dev:

```bash
# Using npm
npm run build    # Copies EPUB then builds web
npm run dev      # No auto-copy (use mise for dev)

# Using mise (recommended)
mise run web:build   # Copies EPUB then builds web
mise run web:dev     # Copies EPUB then starts dev server
mise run dev         # Copies EPUB then starts backend + frontend
```

The script automatically copies `test_multifeature.epub` → `web/public/sample.epub`.

## Workflow

1. **Edit** the test EPUB here in `fixtures/epubs/`
2. **Run** `mise run dev` or `npm run build` - copies to `web/public/` automatically
3. **Tests** use the files directly from `fixtures/epubs/`

No manual synchronization needed! ✅

## Manual Copy (if needed)

```bash
# Using mise
mise run sync:fixtures

# Using npm (build only)
npm run build

# Or run the script directly
./sync_test_fixtures.sh
```

## File Structure

The test EPUB (`sample.epub`) contains:

### Chapter 1 - Começo (Portuguese only)
- Main chapter with footnotes, italic text, and quotes
- Sub-sections: Diário, Correspondência, Notas

### Chapter 2 - Correspondências (Multi-language)
- **Portuguese** (default)
- **English**: `<p lang="en">The letter begins...</p>`
- **Spanish**: `<p lang="es">Más adelante...</p>`
- **Portuguese-BR**: `<p lang="pt-BR">O destinatário...</p>`

## Testing Language Features

The multi-language tags are extracted by `text_formatting.py`:
- HTML `lang` attributes → `[[lang:xx]]` internal tags
- Tags are processed by `LanguageMarkup.parse()`
- Edge TTS uses different voices per language

See tests in `test_epub_multifeature.py`:
- `TestLanguageAttributeExtraction` - Tag extraction tests
- `TestMultilangEpubParsing` - EPUB parsing tests
