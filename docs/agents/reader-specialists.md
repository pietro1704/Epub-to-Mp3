# Native reader specialist ownership

Use these roles only when the work can be split without overlapping files.

| Role | Owns | Evidence |
| --- | --- | --- |
| `reader-layout` | paginated layout, glyph protection, clipping probe, page offsets | layout/unit tests and native pagination probe |
| `reader-transition` | chrome intent, safe-area geometry, navigation, mini-player, transition generation | repeated and interrupted chrome-toggle UI tests |
| `reader-runtime-qa` | simulator/device choreography, seeded LOTR, screenshots and LLDB evidence | real app behavior; app remains open after the run |
| `apple-import` | EPUB/PDF opening, library seed and persisted reader entry | import/open no-crash tests |

The ownership table is not a reason to fan out automatically. Split only when
the files and evidence are independent; otherwise keep one owner responsible
for the complete behavior.
