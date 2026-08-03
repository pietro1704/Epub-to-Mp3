# Domain docs

How engineering skills should consume this repository's domain documentation when exploring the codebase.

## Before exploring, read these

- `CONTEXT.md` at the repository root, or
- `CONTEXT-MAP.md` at the repository root if it exists; it points to one `CONTEXT.md` per context.
- `docs/adr/` for ADRs that affect the area being changed.

If these files do not exist, proceed silently. Do not create them preemptively; domain-modeling work creates them when terminology or decisions are actually resolved.

## File structure

This repository uses the single-context layout:

```
/
├── CONTEXT.md
├── docs/adr/
└── src/
```

## Vocabulary and ADRs

When an issue, proposal, hypothesis, or test names a domain concept, use the terminology defined in `CONTEXT.md`. If a needed concept is absent, reconsider the wording or record the gap for domain-modeling.

If proposed work conflicts with an existing ADR, surface the conflict explicitly instead of silently overriding it.
