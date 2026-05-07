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

## Jardim das Aflições — same TOC depth bug as Mindful Catholic

EPUB has 4-level deep TOC (e.g. ``12.1.1.1``, ``13.1.3.2``). Conversion
generates MP3s only at 3 levels (``12.1.2``, ``13.1.2``). Validator
correctly detects:
- 30+ ``Missing cache files`` for sub-sub-sub chapters
- 20+ ``MP3 filename does not match EPUB heading`` for the same items

Root cause hypothesis (same as Mindful Catholic): the TOC parser in
``ebook_reader.get_chapter_structure`` walks the full hierarchy when
asked, but the conversion path collapses 4-level entries into the
3-level parents. ``validate_conversion`` then sees TOC-derived 4-level
items with no matching cache or MP3.

Books moved to ``~/Downloads/livros/_skipped/``:
- ``The_Mindful_Catholic_Finding_God_One_z_library_sk,_1lib_sk,.epub``
- ``O jardim das Aflições de Epicuro à ressurreicão de César … by Olavo de Carvalho … (z-lib.org).epub``

Fix scope: **non-trivial** — requires either:
(a) parser dedup at ``MAX_CHAPTER_DEPTH`` so reader and converter agree, or
(b) converter respects the full TOC depth and produces MP3s for every leaf, or
(c) validator collapses sub-sub levels to 3 before comparing.

Recommended path: (a) — add ``MAX_CHAPTER_DEPTH=3`` env var
(consistent with the ``MAX_CHAPTER_CHARS`` pattern), enforce in
``get_chapter_structure``. Requires real EPUB fixture for regression test.
