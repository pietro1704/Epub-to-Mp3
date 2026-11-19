# EPUB test fixtures

Checked-in source fixtures: `test_multifeature.epub`, `sample_multilang.epub`
and `footnote_not_in_toc.epub`. Inspect byte identity before treating similarly
named files as aliases. Preserve fixtures and user books.

The multifeature document records Portuguese content, footnotes, italic text,
quotes, subsections and language-tagged passages (`en`, `es`, `pt-BR`). It is
useful for source-fidelity and language-markup regressions, and
`scripts/rails_rust_e2e.sh` converts it through the Rust server and the Rails
gateway. These fixtures do not establish that every current adapter preserves or
synthesizes all those features.

`ruby_app/rails_gateway/public/sample.epub` is a separate consumer artifact; inspect its actual
consumers before changing either copy.
