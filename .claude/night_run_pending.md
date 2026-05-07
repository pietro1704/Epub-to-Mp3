# Night-run pending (2026-05-06)

## Out-of-scope items (need user decision)

### Docker build
- `mise run docker:build` falha com `sh: docker: command not found`
- Docker Desktop / `docker` CLI não está instalado nesta máquina
- HF Spaces builds o Docker via CI; localmente não é blocker
- Sugestão: documentar como opcional ou instalar Docker Desktop


## Resolved

### PR #158: vite 7.3.2 → 8.0.11 (major) — MERGED 2026-05-07
- User approved
- Required changes: bump @vitejs/plugin-react to 6, switch
  manualChunks to function form, replace optimizeDeps.esbuildOptions
  with rolldownOptions (Vite 8 = Rolldown by default)
- Verified: build green, 134/134 tests pass

## Mindful Catholic — TOC structure conflict (needs deeper fix)

EPUB has hybrid TOC: hierarchical (1.0, 1.1, 2.0, 2.1, 2.2) AND flat (1-12)
overlapping the same content. Conversion produces MP3s but with broken
filenames (Chapter 3 missing, Chapter 2 duplicated, hierarchy items overlap
flat ones).

Symptoms:
- 12 chapters reported "Missing cache files" by validator
- Duplicate audio between 2.1 and 2.2
- Chapter 3 MP3 named "8 - CHAPTER SIX..." (filename swap)
- Full book text valid (46k vs 44k normalized — within 5%)

Root cause hypothesis: ebook_reader.get_chapter_structure() generates
overlapping TOC entries from both NCX and nav.xhtml without dedup when
they reference the same anchor with different prefixes.

Fix scope: non-trivial — touches parser hierarchy resolution, dedup
by anchor target. Requires real EPUB fixture for regression test.

Status: kept in source dir, batch halted. Skipping this book for now;
will revisit after smaller books validate clean.
