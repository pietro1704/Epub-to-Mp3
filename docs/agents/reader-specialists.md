# Native reader specialist ownership

Roles map to the registered agents in `.claude/agents/`. Use them only when
the work can be split without overlapping files.

| Role | Agent | Owns | Evidence |
| --- | --- | --- | --- |
| reader-layout | `epub-reader-ui` | paginated layout, glyph protection, clipping probe, page offsets | layout/unit tests and native pagination probe |
| reader-transition | `epub-reader-ui` | chrome intent, safe-area geometry, navigation, mini-player, transition generation | repeated and interrupted chrome-toggle UI tests |
| reader-runtime-qa | `verification-engineer` | simulator/device choreography, seeded LOTR, screenshots and LLDB evidence | real app behavior and verified shutdown after validation; keep open only for a requested review under [execution policy](execution-policy.md) |
| apple-import | `file-picker-uploader` | EPUB/PDF opening, library seed and persisted reader entry | import/open no-crash tests |

The ownership table is not a reason to fan out automatically. Split only when
the files and evidence are independent; otherwise keep one owner responsible
for the complete behavior.
