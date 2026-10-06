# Epub-to-MP3 Reader — Textual Wireframes

## Navigation map

```text
Library
├── Search
├── Import
├── Book detail
│   ├── Read → Reader
│   ├── Listen → Now Playing / chapter queue
│   ├── Table of contents
│   ├── Downloads
│   └── Book metadata/actions
├── Persistent mini-player → Now Playing
└── Settings
    ├── Reader
    ├── Audio and voice
    ├── Conversion provider
    ├── Downloads and storage
    └── Accessibility
```

## 1. Library — iPhone

```text
┌──────────────────────────────┐
│ Library                 [•••] │
│ [Search books…]               │
│ [All] [Reading] [Downloaded]  │
│                              │
│  [cover] Book title           │
│          Author               │
│          42% · Continue       │
│                              │
│  [cover] Another book         │
│          Author               │
│          Not started          │
│                              │
│ ──────────────────────────── │
│ ▶  Book title · Chapter 4   ▷ │  persistent mini-player
│ [Library] [Import] [Settings]│
└──────────────────────────────┘
```

## 2. Library — macOS

```text
┌──────────────┬───────────────────────────┬──────────────────────────────┐
│ Library      │ Books                     │ Selected book                │
│              │ [Search] [Sort] [Filter]  │ [large cover]                │
│ All books    │ [cover] [cover] [cover]   │ Title / author / progress     │
│ Reading      │ [cover] [cover] [cover]   │ [Read] [Listen] [Download]    │
│ Downloaded   │                           │ Table of contents             │
│              │                           │ Recent notes and bookmarks   │
│ Import       │                           │                              │
│ Settings     │                           │ ▶ Chapter 4 · 12:31          │
└──────────────┴───────────────────────────┴──────────────────────────────┘
```

## 3. Import

```text
┌──────────────────────────────┐
│ Add to Library          [×]   │
│                              │
│ [Files] [iCloud] [AirDrop]   │
│ [Share Sheet] [URL]          │
│                              │
│ Supported non-DRM formats    │
│ EPUB · PDF · MOBI · AZW3     │
│ FB2 · CBZ/CBR · DOCX         │
│                              │
│ Importing…                   │
│ Metadata ✓  Cover ✓          │
│ Content indexing…            │
└──────────────────────────────┘
```

## 4. Book detail

```text
┌──────────────────────────────┐
│ [Back]                       │
│          [cover]             │
│        Title                 │
│        Author                │
│        42% · 6h 20m left     │
│ [Read] [Listen] [Download]   │
│                              │
│ Table of contents       [>]  │
│ Audio conversion             │
│   8/24 chapters ready        │
│   [Convert remaining]        │
│ Notes and bookmarks      [>] │
│ File and storage             │
│                              │
│ ▶ Chapter 4 · 12:31          │
└──────────────────────────────┘
```

## 5. Reader

```text
┌──────────────────────────────┐
│ [Back]  Chapter 4       [•••]│
│                              │
│          Chapter title       │
│                              │
│ Paragraph with preserved     │
│ spacing, emphasis, links,    │
│ and semantic structure.      │
│                              │
│ Text selection actions:      │
│ [Highlight] [Note] [Bookmark]│
│                              │
│ [‹] 42%          [TOC] [Aa]  │
│ ▶ Chapter 4 · 12:31      [↑] │
└──────────────────────────────┘
```

Reader controls expose pagination/scrolling, font, size, spacing, margins,
theme, alignment, narration cues, search, TOC, bookmarks, and notes. Footnote
references open the footnote inline or in a native sheet without losing the
reading anchor.

## 6. Now Playing

```text
┌──────────────────────────────┐
│ Now Playing             [Done]│
│                              │
│          [large cover]       │
│ Book title                   │
│ Chapter 4                    │
│                              │
│ ───────●──────────── 12:31   │
│ [−] 1.0× [+]                 │
│                              │
│       [◀] [Pause] [▶]        │
│ [Previous] [Chapter queue]   │
│                              │
│ Next: Chapter 5              │
│ Downloaded ✓ · On device     │
└──────────────────────────────┘
```

The player is a global application service, not a reader-only view. It
persists through navigation, supports background audio, and publishes state to
Apple system media surfaces.

## 7. Conversion sheet

```text
┌──────────────────────────────┐
│ Create audiobook              │
│                              │
│ Scope                        │
│ (•) Current chapter          │
│ ( ) Selected chapters        │
│ ( ) Entire book              │
│                              │
│ Provider                     │
│ (•) On this device           │
│ ( ) Server                   │
│                              │
│ Voice  Default               │
│ Language  Automatic          │
│ Speed  1.0×                  │
│                              │
│ [Cancel]       [Start]       │
└──────────────────────────────┘
```

## 8. Settings

```text
Settings
├── Reader: theme, font, size, spacing, margins, pagination/scrolling
├── Audio: voice, language, speed, structural cues, default behavior
├── Conversion: on-device/server, retries, Wi‑Fi/download policy
├── Storage: cache, downloads, cleanup, available space
├── Accessibility: Dynamic Type-compatible sizing, VoiceOver, contrast
└── About and diagnostics
```

## Interaction rules

- Tapping Read always restores the exact last semantic anchor when available.
- Tapping Listen opens or resumes the global player without forcing the reader
  to close.
- A completed chapter is playable immediately; conversion progress is visible
  at chapter and book level.
- Download state is explicit and survives app relaunch.
- The mini-player never hides critical reader controls and expands to Now
  Playing with a standard native transition.
