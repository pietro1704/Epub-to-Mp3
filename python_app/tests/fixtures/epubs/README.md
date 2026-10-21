# EPUB test fixtures

This directory contains checked-in source fixtures, including
`test_multifeature.epub` and `sample_multilang.epub`. Inspect byte identity before
treating similarly named files as aliases. Preserve fixtures and user books.

The multifeature document records Portuguese content, footnotes, italic text,
quotes, subsections and language-tagged passages (`en`, `es`, `pt-BR`). It is useful
for source-fidelity and language-markup regressions. Legacy parsing expectations
live in `test_epub_multifeature.py`; they do not establish that every current
adapter preserves or synthesizes all those features.

`web/public/sample.epub` is a separate consumer artifact. The current root
`mise.toml` and `web/package.json` do not define the old `sync:fixtures`,
`web:build` or `web:dev` synchronization recipe, and the former
`sync_test_fixtures.sh` is absent. Do not assume `npm run build` or `mise run dev`
copies this fixture automatically. Inspect actual consumers and review any
explicit fixture-copy change, preserving intended identity/content.

The historical Python `lang` → `[[lang:xx]]` markup contract is legacy evidence,
not permission to use online voices. Edge requires explicit consent; Piper and
installed native fallback policy remain authoritative. Python execution is
CI-only under [execution policy](../../../../docs/agents/execution-policy.md).
