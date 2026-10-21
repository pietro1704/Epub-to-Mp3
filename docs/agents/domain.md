# Domain docs

How engineering skills should consume this repository's domain documentation when exploring the codebase.

## Before exploring, read these

- `CONTEXT.md` at the repository root, or
- `CONTEXT-MAP.md` at the repository root if it exists; it points to one `CONTEXT.md` per context.
- `docs/adr/` for ADRs that affect the area being changed.
- A nested `AGENTS.md` for the affected product surface. Native reader work
  must read `ios/EpubToMp3/AGENTS.md`.

If these files do not exist, proceed silently. Do not create them preemptively; domain-modeling work creates them when terminology or decisions are actually resolved.

## Existing layout

This repository uses one root `CONTEXT.md` and `docs/adr/`. Consult actual module
paths in the relevant runtime navigation; the domain layout does not prescribe
one source directory. Keep this naming when adapting generic GLOSSARY examples.

## Vocabulary and ADRs

When an issue, proposal, hypothesis, or test names a domain concept, use the terminology defined in `CONTEXT.md`. If a needed concept is absent, reconsider the wording or record the gap for domain-modeling.

If proposed work conflicts with an existing ADR, surface the conflict explicitly instead of silently overriding it.
